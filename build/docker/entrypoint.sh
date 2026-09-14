#!/bin/bash
# =============================================================================
#  entrypoint.sh — 薄容器内的唯一逻辑
# =============================================================================
#  设计约束：**不重写任何构建逻辑**。
#  真正的构建完全交给仓库里既有的两个脚本；这里只做三件事：
#
#    1) 环境自检（root / 仓库挂载 / qemu binfmt / 磁盘）
#    2) 调用 scripts/build-rootfs.sh
#    3) 做「容器适配清理」，然后调用 build/mk-image.sh
#
#  为什么需要「容器适配清理」：
#    原脚本是按裸机设计的，容器里有两个额外的坑必须补：
#      a) build-rootfs.sh 会 mount /dev 进 chroot。在 --privileged 下容器
#         的 /dev 就是宿主 /dev，若卸载不干净，mkfs.ext4 -d 会把宿主设备
#         节点灌进 img（体积暴涨 + 镜像不可用）。
#      b) build-rootfs.sh 会把 x86_64 的 qemu-aarch64-static 拷进 arm64
#         rootfs 用于 cross 构建，但不会删掉，会一起打进 img。
# =============================================================================
set -eE
trap 'echo "Error: in $0 on line $LINENO" >&2' ERR

REPO="${REPO:-/work/kali-rootfs}"
BOARD="${BOARD:-lubancat-4}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

log()  { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# =============================================================================
#  1. 环境自检
# =============================================================================
log "[自检] 运行环境"

[ "$(id -u)" -eq 0 ] || die "必须以 root 运行容器（请在 docker run 时加 --privileged）"
[ -d "$REPO/scripts" ] || die "仓库未挂载到 $REPO（请用 -v <仓库根>:$REPO）"
[ -f "$REPO/scripts/build-rootfs.sh" ] || die "$REPO/scripts/build-rootfs.sh 不存在"
[ -f "$REPO/build/mk-image.sh" ] || die "$REPO/build/mk-image.sh 不存在"

echo "    仓库      : $REPO"
echo "    板卡      : $BOARD"
echo "    内核      : $(uname -r) / $(uname -m)"

# --- binfmt 检查（关键）------------------------------------------------------
#  容器是 x86_64，而 debootstrap 的第二阶段要执行 arm64 的 apt/dpkg。
#  这依赖宿主机注册的 qemu-aarch64 binfmt。binfmt_misc 是跨 namespace 全局
#  共享的，所以只要宿主注册过（带 F 标志），容器内无需额外权限即可使用。
#
#  如果没注册，后面的 chroot 会报 "Exec format error" —— 那个报错对使用者
#  毫无提示作用，所以这里提前检查并给出明确的修复指引。
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    cat >&2 <<'EOF'

ERROR: 宿主机的 qemu-aarch64 binfmt 未注册。

  容器是 x86_64 架构，而 kali rootfs 是 arm64，debootstrap 的第二阶段
  需要在 chroot 内执行 arm64 的 apt/dpkg，这依赖 qemu 用户态模拟。

  请在【宿主机】（不是容器内）执行以下任一种：

    A. 安装系统包（推荐，永久生效）
         sudo apt-get install -y qemu-user-static binfmt-support
         sudo systemctl restart systemd-binfmt
         # 或者： sudo update-binfmts --enable qemu-aarch64

    B. 用官方镜像一次性注册（需要 --privileged）
         docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

  验证：
         cat /proc/sys/fs/binfmt_misc/qemu-aarch64    # 应输出 enabled

EOF
    exit 1
fi
echo "    binfmt    : qemu-aarch64 已注册"

# --- 磁盘空间检查 ------------------------------------------------------------
#  峰值需求：rootfs 目录树 + rootfs.img 在 mkfs.ext4 -d 期间并存
#            （各 5~10GB） + swapfile 2GB + apt 缓存。建议预留 20GB 以上。
AVAIL_MB=$(df -Pm "$REPO" | awk 'NR==2 {print $4}')
if [ "${AVAIL_MB:-0}" -lt 15000 ]; then
    warn "可用磁盘仅 ${AVAIL_MB}MB，构建峰值可能需要 20GB 以上，可能中途失败"
else
    echo "    可用磁盘  : ${AVAIL_MB}MB"
fi

# =============================================================================
#  2. 生成 rootfs 目录树（调用原脚本）
# =============================================================================
if [ "$FORCE_REBUILD" = "1" ] && [ -f "$REPO/build/rootfs.img" ]; then
    log "[0/3] FORCE_REBUILD=1，删除已有 rootfs.img 以触发全量重建"
    rm -f "$REPO/build/rootfs.img"
fi

log "[1/3] 调用 scripts/build-rootfs.sh"
cd "$REPO"
bash scripts/build-rootfs.sh

[ -d "$REPO/build/rootfs" ] || die "build/rootfs 未生成，构建可能失败"

# 如果脚本因为短路逻辑跳过了构建，rootfs 目录可能不存在或不完整
if [ ! -x "$REPO/build/rootfs/bin/bash" ] && [ ! -x "$REPO/build/rootfs/usr/bin/bash" ]; then
    warn "build/rootfs 下未见 bash，目录可能不完整"
fi

# =============================================================================
#  3. 容器适配清理（在打包之前）
# =============================================================================
log "[2/3] 容器适配清理"

# --- 3.1 挂载残留清理（最重要的一步）-----------------------------------------
#  build-rootfs.sh 第 67-70 行 mount 了 proc/sysfs/dev，第 290-291 行 umount。
#  但第 291 行是 `umount -lf ${chroot_dir}/*`（通配展开），在容器里不一定能
#  把所有挂载点清干净。残留的后果很严重：
#      mkfs.ext4 -d rootfs  →  把宿主 /dev 的几百个设备节点灌进 img
#  这里做「显式卸载 + 反查兜底 + 二次校验」三重防护。
ROOTFS="$REPO/build/rootfs"
[ -d "$ROOTFS" ] || die "rootfs 目录不存在: $ROOTFS"

umount_one() {
    local target="$1"
    [ -n "$target" ] || return 0
    if mountpoint -q "$target" 2>/dev/null; then
        echo "    卸载 $target"
        umount -lf "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || true
    fi
}

# 3.1.a 按常见挂载点显式卸载（顺序：深的先卸）
for d in dev/pts dev/shm proc sys dev run; do
    umount_one "$ROOTFS/$d"
done

# 3.1.b 反查兜底：处理非标准位置的挂载
if command -v findmnt >/dev/null 2>&1; then
    while read -r mp; do
        [ -n "$mp" ] && [ "$mp" != "$ROOTFS" ] && umount_one "$mp"
    done < <(findmnt -Rrn -o TARGET "$ROOTFS" 2>/dev/null || true)
fi

# 3.1.c 二次校验：仍有挂载就拒绝打包
if command -v findmnt >/dev/null 2>&1 && findmnt -Rrn -o TARGET "$ROOTFS" 2>/dev/null | grep -q .; then
    echo "--- 残留挂载点 ---" >&2
    findmnt -Rr "$ROOTFS" >&2 || true
    die "build/rootfs 下仍有挂载点，拒绝打包以免污染 img"
fi
echo "    挂载点    : 已清理干净"

# --- 3.2 删除构建期专用的 qemu -------------------------------------------------
#  原脚本第 51 行 `sudo cp /usr/bin/qemu-aarch64-static ${chroot_dir}/usr/bin/`，
#  这是 x86_64 二进制（约 5MB），只为交叉构建服务。
#  留在 arm64 rootfs 里毫无用处，还会被打进 img。原脚本没删，这里补一刀。
QEMU_IN_ROOTFS="$ROOTFS/usr/bin/qemu-aarch64-static"
if [ -f "$QEMU_IN_ROOTFS" ]; then
    rm -f "$QEMU_IN_ROOTFS"
    echo "    已删除    : usr/bin/qemu-aarch64-static（构建期专用）"
fi

# --- 3.3 补调 board hook -------------------------------------------------------
#  config/boards/<board>.conf 里的 config_image_hook__<board>() 函数只被
#  scripts/config-image.sh 调用；build-rootfs.sh 和 mk-image.sh 都不碰它。
#
#  不补调会丢三个功能：
#    * 90-naming-audios.rules      声卡命名（HDMI0/DP0/ES8388）
#    * rtl8852be-reload.service    修 RTL8852BE 开蓝牙时 WiFi 掉线
#    * alsa-audio-config.service   HDMI/ES8388 音频初始化
#
#  这里的做法是把 config-image.sh 里本来就有的那段调用搬过来 ——
#  source 仓库自带的函数定义，不修改任何脚本。
BOARD_CONF="$REPO/config/boards/${BOARD}.conf"
if [ -f "$BOARD_CONF" ]; then
    # board conf 内部用 ${chroot_dir} / ${overlay_dir}，必须提供这两个变量
    export chroot_dir="$ROOTFS"
    export overlay_dir="$REPO/overlay"

    # shellcheck disable=SC1090
    source "$BOARD_CONF"

    if declare -F "config_image_hook__${BOARD}" >/dev/null 2>&1; then
        echo "    执行 hook : config_image_hook__${BOARD}"

        # hook 内部会 `chroot ... systemctl enable`，需要伪文件系统可用
        mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/dev/pts"
        mount -t proc  /proc "$ROOTFS/proc" 2>/dev/null || warn "无法挂载 $ROOTFS/proc"
        mount -t sysfs /sys  "$ROOTFS/sys"  2>/dev/null || warn "无法挂载 $ROOTFS/sys"
        mount -o bind  /dev  "$ROOTFS/dev"  2>/dev/null || warn "无法 bind $ROOTFS/dev"

        rc=0
        "config_image_hook__${BOARD}" || rc=$?

        umount -lf "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc" 2>/dev/null || true

        [ "$rc" -eq 0 ] || warn "board hook 返回 $rc，请检查日志"
    else
        echo "    board conf 中未定义 config_image_hook__${BOARD}()，跳过"
    fi
else
    echo "    未找到 $BOARD_CONF，跳过 board hook"
fi

# 3.4 hook 之后可能又产生挂载，再清一次
for d in dev/pts dev proc sys run; do
    umount_one "$ROOTFS/$d"
done

# --- 3.5 rootfs 体积快照（便于在日志里直接看到效果）----------------------------
ROOTFS_SIZE=$(du -sh --apparent-size "$ROOTFS" 2>/dev/null | cut -f1 || echo "?")
echo "    rootfs 大小: ${ROOTFS_SIZE}"

# =============================================================================
#  4. 打包成 rootfs.img（调用原脚本）
# =============================================================================
log "[3/3] 调用 build/mk-image.sh"

# --- e2fsck 返回码陷阱 ---------------------------------------------------------
#  mk-image.sh 第 1 行是 `#!/bin/bash -e`（即 set -e），而它第 29 行执行
#  `sudo e2fsck -p -f`。e2fsck -p 的返回码语义：
#      0 = 无错误        1 = 已修复错误
#      2 = 已修复需重启   4 = 未修复的错误
#  返回 1 或 2 时会触发脚本自身的 set -e，导致后面的 `resize2fs -M` 不执行
#  （img 不会收缩到最小，体积偏大）。
#
#  set -e 来自 shebang，无法从外部关闭，所以这里改为「以产物为准」：
#  捕获返回码，只要 rootfs.img 产出成功，就补一次幂等的收尾操作。
cd "$REPO/build"

set +e
bash mk-image.sh rootfs
MK_RC=$?
set -e

if [ ! -f "$REPO/build/rootfs.img" ]; then
    die "mk-image.sh 失败（返回码 $MK_RC）且未产出 rootfs.img"
fi

if [ "$MK_RC" -ne 0 ]; then
    warn "mk-image.sh 返回 $MK_RC（多半是 e2fsck -p 的非零返回），补一次幂等收尾"

    # e2fsck 显式吸收返回码（这正是修复场景下的正常返回）
    e2fsck -pf "$REPO/build/rootfs.img" || true

    # resize2fs -M 是幂等的：文件系统已最小化时输出 "Nothing to do"，无害
    resize2fs -M "$REPO/build/rootfs.img" || true
fi

# =============================================================================
#  5. 完成
# =============================================================================
log "构建完成"
ls -lh "$REPO/build/rootfs.img"

cat <<EOF

  产物路径（宿主）: build/rootfs.img
  rootfs 目录树    : build/rootfs/

  烧写到根分区：
      sudo dd if=build/rootfs.img of=/dev/mmcblk0pX bs=1M status=progress conv=fsync

  做完整可启动 img（含 boot 分区与 U-Boot）：
      见 scripts/build-image.sh（需要它自己的输入格式）

EOF

exit 0
