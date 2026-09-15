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
SKIP_KERNEL_CHECK="${SKIP_KERNEL_CHECK:-0}"

log()  { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 内核版本判定辅助（与 build.sh 内置同一份，保持两个脚本各自独立可跑）-------
#  只用 bash 参数展开解析主.次版本号；解析不出数字时放行，绝不误拦。
#  注意：本脚本是 set -eE + ERR trap，每个分支都必须返回 0，否则赋值语境会中断。
kernel_majmin() {
    local rel="$1" head maj min
    [ -n "$rel" ] || return 0
    head="${rel%%[!0-9.]*}"             # 5.4.0-216-generic -> 5.4.0
    [ -n "$head" ] || return 0
    maj="${head%%.*}"
    min="${head#*.}"; min="${min%%.*}"
    case "${maj}${min}" in *[!0-9]*) return 0 ;; esac   # 解析不出数字 -> 放行
    [ -n "$maj" ] || return 0
    [ -n "$min" ] || min=0
    printf '%s %s' "$maj" "$min"
}

# 分级：hard(<5.10) / soft(5.10~5.13) / ok(>=5.14)；解析失败一律 ok（不误拦）
kernel_grade() {
    local mm maj min
    mm="$(kernel_majmin "$1")"
    [ -n "$mm" ] || { printf ok; return 0; }
    maj="${mm%% *}"; min="${mm##* }"
    if [ "$maj" -lt 5 ] || { [ "$maj" -eq 5 ] && [ "$min" -lt 10 ]; }; then
        printf hard
    elif [ "$maj" -eq 5 ] && [ "$min" -lt 14 ]; then
        printf soft
    else
        printf ok
    fi
}

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

# --- 宿主内核版本预检 ----------------------------------------------------------
#  容器与宿主共享内核，此处 uname -r 读到的就是宿主内核，判定可靠，故做成硬报错。
#  systemd 260+ 的内核基线是 5.10，低于基线时 chroot 内 apt/dpkg 会大面积失败。
#  与 build.sh 构成双保险：覆盖手动 docker run 与 CI 直跑容器的路径。
if [ "${SKIP_KERNEL_CHECK}" != "1" ]; then
    case "$(kernel_grade "$(uname -r)")" in
        hard)
            die "宿主内核版本过低（$(uname -r)），Kali-rolling 的 systemd 260+ 要求内核 ≥ 5.10；请升级内核（参见根 README 2.1）或改用内核 6.8 的 CI 构建"
            ;;
        soft)
            warn "宿主内核 $(uname -r) 介于 5.10~5.13，低于 systemd 推荐基线 5.14，建议升级内核"
            ;;
        *)
            :   # ≥ 5.14 静默通过
            ;;
    esac
fi

# --- binfmt 检查（仅交叉构建需要）---------------------------------------------
#  ★ 判据必须用【容器自身】架构，不能无条件检查。
#
#  为什么：build-rootfs.sh 第 50 行按 `[ -f /usr/bin/qemu-aarch64-static ]`
#  分流两条路径：
#
#    容器是 x86_64 → 走 --foreign + chroot second-stage，**需要 binfmt**
#    容器是 arm64  → 走原生 debootstrap，**完全不需要 binfmt**
#
#  所以 arm64 runner 上 /proc/sys/fs/binfmt_misc/qemu-aarch64 不存在是
#  **正常现象**，早期版本在这里无条件报错退出，导致 arm64 腿必然失败。
#
#  binfmt_misc 是跨 namespace 全局共享的，只要宿主注册过（带 F 标志），
#  容器内无需额外权限即可使用 —— 所以检查看的是宿主注册状态。
CONTAINER_ARCH="$(uname -m)"
case "$CONTAINER_ARCH" in
    aarch64|arm64)
        echo "    binfmt    : 原生 arm64，无需 qemu（build-rootfs.sh 走 else 分支）"
        ;;
    *)
        # --- 交叉构建前置 1/2：-static 别名（自愈，兼容新版 Debian/Kali）--------
        #  build-rootfs.sh 第 50 行看的是 /usr/bin/qemu-aarch64-static，
        #  但该文件名在现代 Debian/Kali 上已不存在：
        #    ① qemu 1:9.1.0（2024-09）起 qemu-user 本身改为静态链接，
        #       二进制名去掉了 -static 后缀（真身是 /usr/bin/qemu-aarch64）；
        #    ② Debian #1124747（2026-01）删除了提供兼容软链的 qemu-user-static
        #       包，改由 qemu-user-binfmt 的 Provides: 承接 ——
        #       于是 apt 装得上，却**不再创建任何 -static 软链**。
        #  不修的话第 50 行恒为假，会静默改走原生分支（与设计不符）。
        #  这里就地补软链：目标是静态二进制，语义成立；第 54 行 cp 也照常可用。
        if [ ! -e /usr/bin/qemu-aarch64-static ]; then
            if [ -x /usr/bin/qemu-aarch64 ]; then
                ln -sf /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static
                echo "    qemu 别名 : 已补 /usr/bin/qemu-aarch64-static -> qemu-aarch64"
            else
                warn "容器内既无 /usr/bin/qemu-aarch64-static 也无 /usr/bin/qemu-aarch64"
                warn "build-rootfs.sh 将改走原生分支；若 binfmt 已注册通常仍可完成构建"
            fi
        else
            echo "    qemu 别名 : /usr/bin/qemu-aarch64-static 已就绪"
        fi

        # --- 交叉构建前置 2/2：宿主 binfmt 注册 --------------------------------
        #  ⚠ 关键细节（曾在此处误判）：
        #  /proc/sys/fs/binfmt_misc 是**伪文件系统**，其内容**不跨 mount
        #  namespace 传播**。容器的 /proc 是独立的 procfs 实例，宿主上的
        #  binfmt_misc 挂载不会传播进来 —— 所以在容器里**默认根本看不到**
        #  /proc/sys/fs/binfmt_misc/qemu-aarch64，哪怕宿主已注册且功能正常。
        #
        #  但**执行**是没问题的：binfmt_misc 注册是内核全局状态，且
        #  multiarch/qemu-user-static --reset -p yes 会带 F(fix_binary) 标志 ——
        #  内核在注册时就打开了 qemu 二进制，之后无论在哪个 namespace 都能用。
        #  这正是 `docker run --platform linux/arm64 alpine uname -m` 能成功的原因。
        #
        #  所以判据要分三层：
        #    ① 先尝试自己挂 binfmt_misc（--privileged 允许）→ 挂上后读到的是
        #       全局状态，可据此准确判断
        #    ② 挂上了但没条目 → 宿主确实没注册 → 报错退出
        #    ③ 挂不上 → 无法判定 → 只告警，不阻断（宿主机侧的检查才是权威）
        #
        #  判定「确实挂上了」用 $BINFMT_DIR/status 是否存在 —— 真正的
        #  binfmt_misc 文件系统会暴露一个 status 文件（内容 enabled/disabled）。
        #  不能用 mountpoint -q：若有人 bind-mount 了一个空目录到该路径，
        #  mountpoint 也返回真，会让我们误判成「挂上了但没注册」。
        BINFMT_DIR=/proc/sys/fs/binfmt_misc
        BINFMT_MOUNTED=0

        if [ ! -f "$BINFMT_DIR/qemu-aarch64" ]; then
            mkdir -p "$BINFMT_DIR" 2>/dev/null || true
            mount -t binfmt_misc binfmt_misc "$BINFMT_DIR" 2>/dev/null || true
        fi
        if [ -f "$BINFMT_DIR/status" ]; then
            BINFMT_MOUNTED=1
        fi

        if [ -f "$BINFMT_DIR/qemu-aarch64" ]; then
            echo "    binfmt    : qemu-aarch64 已注册（交叉构建模式）"
            # F 标志 = fix binary：内核已缓存解释器，chroot 内执行 arm64 不依赖
            # 容器 namespace 里能否找到 qemu 文件。没有 F 时容易踩坑，提示一下。
            if grep -q '^flags:.*F' "$BINFMT_DIR/qemu-aarch64" 2>/dev/null; then
                echo "    binfmt F  : 已置位（内核已缓存解释器，namespace 无关）"
            else
                warn "binfmt 未带 F(fix_binary) 标志 —— chroot 内执行 arm64 可能失败。"
                warn "修复：用 multiarch/qemu-user-static --reset -p yes 重新注册（-p 即 persistent/F）。"
            fi
        elif [ "$BINFMT_MOUNTED" = "1" ]; then
            # 挂载成功却读不到条目 → 宿主确实没注册，这是真错误
            cat >&2 <<EOF

ERROR: 宿主机未注册 qemu-aarch64 binfmt。
       （已在容器内挂载 binfmt_misc 并确认该条目不存在，判定可靠）

  容器是 ${CONTAINER_ARCH} 架构，而 kali rootfs 是 arm64，debootstrap 的
  第二阶段需要在 chroot 内执行 arm64 的 apt/dpkg，这依赖 qemu 用户态模拟。

  请在【宿主机】（不是容器内）执行以下任一种：

    A. 用官方镜像一次性注册（最简单，推荐）
         docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

    B. 安装系统包（永久生效；注意新版 Debian/Kali 已无 qemu-user-static 包）
         sudo apt-get install -y qemu-user qemu-user-binfmt
         sudo systemctl restart systemd-binfmt
         # 或者： sudo update-binfmts --enable qemu-aarch64

  验证（在宿主机上跑）：
         cat /proc/sys/fs/binfmt_misc/qemu-aarch64    # 应看到 enabled 与 flags: ...F

EOF
            exit 1
        else
            # 无法判定：不阻断。执行本身依赖内核全局状态，与 namespace 可见性无关；
            # 宿主机侧（build.sh / CI 注册步骤）已做过权威校验。
            warn "无法在容器内读取 /proc/sys/fs/binfmt_misc：该伪文件系统的内容"
            warn "不跨 mount namespace 传播，且本容器未能自行挂载它。"
            warn "跳过容器内检查 —— 判定以宿主机侧为准（build.sh 或 CI 的注册步骤）。"
            warn "若随后 debootstrap 报 'Exec format error'，请回到宿主机注册 binfmt。"
        fi
        ;;
esac

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
