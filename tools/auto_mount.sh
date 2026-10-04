#!/bin/bash

# 挂载所有未挂载的独立文件系统；多设备 btrfs 卷
# 成员盘共享 label 和 UUID，内核挂载表只记一个成员，按 UUID 判断是否已挂
# 并按 UUID 去重，避免同一卷被挂多次（Thunar 出现 HD1T 和 HD1T1）
mount_unmounted_disks() {
    # 用户不在 plugdev 组时 udisksctl mount 会要密码，免密挂载失效
    if ! groups | grep -q '\bplugdev\b'; then
        echo "❌ 当前用户不在 plugdev 组中，无法 udisksctl 免密挂载。请将用户添加到 plugdev 组后再运行此脚本。"
        exit 1
    fi

    echo "正在扫描系统中的未挂载硬盘..."

    local mounted_uuids label_path LABEL real_dev UUID FSTYPE
    local -A seen_uuid

    mounted_uuids=$(findmnt -rn -o UUID 2>/dev/null)

    for label_path in /dev/disk/by-label/*; do
        # 确保该路径是个合法的块设备，防止空目录报错
        [ -b "${label_path}" ] || continue

        LABEL=$(basename "${label_path}")
        real_dev=$(readlink -f "${label_path}")
        UUID=$(lsblk -ndo UUID "${real_dev}" 2>/dev/null)
        FSTYPE=$(lsblk -ndo FSTYPE "${real_dev}" 2>/dev/null)

        # 软RAID/LVM/LUKS/ZFS 成员盘与 swap 不是可独立挂载的文件系统，跳过
        case "${FSTYPE}" in
            zfs_member|linux_raid_member|LVM2_member|crypto_LUKS|swap)
                echo "跳过 ${LABEL}（${FSTYPE}，非独立文件系统）"
                continue
                ;;
        esac

        # 同一文件系统（UUID 相同）只处理一次
        if [ -n "${UUID}" ]; then
            if [ -n "${seen_uuid[${UUID}]:-}" ]; then
                continue
            fi
            seen_uuid[${UUID}]=1
        fi

        # 该文件系统已经处于挂载状态（无论挂到哪、由谁挂的）就跳过
        if [ -n "${UUID}" ] && printf '%s\n' "${mounted_uuids}" | grep -Fqx "${UUID}"; then
            echo "硬盘 ${LABEL} 已经处于挂载状态，跳过。"
            continue
        fi

        echo "发现未挂载硬盘: ${LABEL}，正在自动挂载..."
        # 执行挂载（无需密码，静默运行）
        udisksctl mount -b "${label_path}" >/dev/null 2>&1
    done

    echo "所有可用硬盘动态挂载完毕！"
}

# 把所有已挂载的带 label 文件系统合并到 /neo（含机械盘）；
# 不依赖 label 命名；不写 fstab，由本脚本负责挂载，已挂载则跳过
mount_mergerfs_pool() {
    local POOL="/neo"
    local MERGERFS_OPTS="cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,allow_other"
    local label_path LABEL real_dev FSTYPE target branch_str
    local -a branches=()

    if findmnt -rn "${POOL}" >/dev/null 2>&1; then
        echo "mergerfs 池已挂载到 ${POOL}，跳过。"
        return
    fi

    for label_path in /dev/disk/by-label/*; do
        [ -b "${label_path}" ] || continue
        LABEL=$(basename "${label_path}")
        real_dev=$(readlink -f "${label_path}")
        FSTYPE=$(lsblk -ndo FSTYPE "${real_dev}" 2>/dev/null | tr -d '[:space:]')

        case "${FSTYPE}" in
            zfs_member|linux_raid_member|LVM2_member|crypto_LUKS|swap) continue ;;
        esac

        target=$(findmnt -rn -S "LABEL=${LABEL}" -o TARGET 2>/dev/null)
        if [ -n "${target}" ]; then
            branches+=("${target}")
            # udisks 挂载点可能 root:root 无 ACL；pfrd 会选中任一分支建文件，不可写则池写入失败
            if [ ! -w "${target}" ]; then
                sudo chown "$(id -u):$(id -g)" "${target}"
            fi
        else
            echo "⚠️ ${LABEL} 未挂载，不加入 mergerfs 池。"
        fi
    done

    if [ "${#branches[@]}" -eq 0 ]; then
        echo "❌ 无任何分支已挂载，跳过 mergerfs。"
        return
    fi

    branch_str=$(IFS=:; echo "${branches[*]}")
    if mergerfs -o "${MERGERFS_OPTS}" "${branch_str}" "${POOL}"; then
        echo "✅ mergerfs 已挂载到 ${POOL}（分支: ${branch_str}）"
    else
        echo "❌ mergerfs 挂载失败。"
    fi
}

# 列出某 label 盘的快照；不传 label 则遍历所有已挂载的 btrfs 数据盘
# 快照固定放 <挂载点>/.snapshots/，只认这个前缀；返回 0 表示有结果、1 表示无
# 需要 sudo -n 免密：btrfs subvolume list 走 TREE_SEARCH ioctl，非 root 必 EPERM
list_snapshots() {
    local filter="${1:-}"
    local label_path LABEL target rel creation flags
    local matched=0

    for label_path in /dev/disk/by-label/*; do
        [ -b "${label_path}" ] || continue
        LABEL=$(basename "${label_path}")
        if [ -n "${filter}" ] && [ "${LABEL}" != "${filter}" ]; then
            continue
        fi

        target=$(findmnt -rn -S "LABEL=${LABEL}" -o TARGET 2>/dev/null)
        if [ -z "${target}" ]; then
            echo "⚠️ ${LABEL} 未挂载，跳过。"
            continue
        fi
        if [ "$(findmnt -rn -S "LABEL=${LABEL}" -o FSTYPE 2>/dev/null)" != "btrfs" ]; then
            echo "⚠️ ${LABEL} 不是 btrfs，无快照。"
            continue
        fi

        while IFS= read -r rel; do
            [ -n "${rel}" ] || continue
            matched=1
            # show 输出每行以 tab 开头，正则要允许前导空白
            creation=$(sudo -n btrfs subvolume show "${target}/${rel}" 2>/dev/null \
                | sed -n 's/^[[:space:]]*Creation time:[[:space:]]*//p')
            flags=$(sudo -n btrfs subvolume show "${target}/${rel}" 2>/dev/null \
                | sed -n 's/^[[:space:]]*Flags:[[:space:]]*//p')
            printf '%-10s %-45s %s  [%s]\n' "${LABEL}" "${rel}" "${creation:-?}" "${flags:--}"
        done < <(sudo -n btrfs subvolume list -s "${target}" 2>/dev/null \
            | awk -F'path ' 'index($2, ".snapshots/")==1 {print $2}')
    done

    if [ "${matched}" -eq 0 ]; then
        echo "没有找到任何快照。"
        return 1
    fi
}

# 给指定 label 盘的整盘根子卷建只读快照，落盘到 <挂载点>/.snapshots/<label>_<时间>
# 目标必须在同一文件系统内，只能放盘内部；快照内会看到一个空的 .snapshots 目录
# （btrfs 快照不递归嵌套子卷），属正常现象。挂载点属主是当前用户，mkdir 无需 sudo
create_snapshot() {
    local LABEL="${1:?用法: $0 snap-create <LABEL>}"
    local label_path target dest name

    label_path="/dev/disk/by-label/${LABEL}"
    if [ ! -b "${label_path}" ]; then
        echo "❌ 找不到 label 为 ${LABEL} 的块设备。"
        return 1
    fi

    target=$(findmnt -rn -S "LABEL=${LABEL}" -o TARGET 2>/dev/null)
    if [ -z "${target}" ]; then
        echo "❌ ${LABEL} 未挂载，先跑 $0 挂载。"
        return 1
    fi
    if [ "$(findmnt -rn -S "LABEL=${LABEL}" -o FSTYPE 2>/dev/null)" != "btrfs" ]; then
        echo "❌ ${LABEL} 不是 btrfs，无法建快照。"
        return 1
    fi

    name="${LABEL}_$(date +%Y%m%d-%H%M%S)"
    dest="${target}/.snapshots/${name}"
    if [ -e "${dest}" ]; then
        echo "❌ 快照 ${dest} 已存在（同一秒内重复创建）。"
        return 1
    fi

    mkdir -p "${target}/.snapshots"
    if sudo -n btrfs subvolume snapshot -r "${target}" "${dest}"; then
        echo "✅ 已创建只读快照 ${dest}"
    else
        echo "❌ 快照创建失败（确认 sudo -n 免密可用）。"
        return 1
    fi
}

# 已运行则跳过；首次启动 kodi 可能较慢，错误不中断主流程
start_kodi() {
    if ! command -v kodi >/dev/null 2>&1; then
        echo "❌ 错误：未检测到 Kodi 可执行文件，请先安装 Kodi。"
        return
    fi

    if pgrep -x kodi >/dev/null 2>&1; then
        echo "⚠️ Kodi 已经在运行中，跳过启动。"
        return
    fi

    echo "⚡ 注意：首次启动 Kodi 可能需要一些时间，请耐心等待..."
    nohup kodi --audio-backend=alsa >/dev/null 2>&1 &
}

usage() {
    cat <<EOF
用法: $0 [命令]
  （无参数）        挂载所有硬盘 + 挂载 mergerfs 池 + 启动 kodi
  snap-list [LABEL] 列出快照（不传 LABEL 列全部盘）
  snap-create LABEL  给 LABEL 盘建只读快照
EOF
}

case "${1:-}" in
    "")
        mount_unmounted_disks
        mount_mergerfs_pool
        start_kodi
        ;;
    snap-list)
        list_snapshots "${2:-}"
        ;;
    snap-create)
        create_snapshot "${2:-}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
