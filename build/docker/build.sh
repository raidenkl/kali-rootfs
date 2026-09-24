#!/bin/bash
# =============================================================================
#  build.sh — 宿主机一键入口
# =============================================================================
#  做两件事：
#    1) 构建薄容器镜像（只装依赖，不含构建逻辑）
#    2) 以挂载方式运行容器，由容器内的 entrypoint.sh 调用仓库原脚本
#
#  用法：
#      bash build/docker/build.sh                    # 完整流程
#      REBUILD=0 bash build/docker/build.sh          # 不重建镜像，直接跑
#      FORCE_REBUILD=1 bash build/docker/build.sh    # 忽略 rootfs.img 强制全量重建
#      BOARD=lubancat-5 bash build/docker/build.sh   # 换板卡
#      GPU_STACK=both bash build/docker/build.sh     # 预装 GPU 驱动栈（见下）
#      SKIP_KERNEL_CHECK=1 bash build/docker/build.sh  # 跳过宿主内核预检（不推荐）
#
#  GPU_STACK（默认 none，也可写进 config/gpu-stack.conf 免得每次带）：
#      none      不装，Kali 官方 Mesa（GL 走 llvmpipe 软渲染）
#      panfork   装 panfork mesa → X11 桌面 GL / glamor 硬件加速
#      libmali   装 Rockchip 闭源 libmali → GLES/EGL/Vulkan/OpenCL/无 X 的 GBM
#      both      两者都装（推荐）：桌面走 panfork，计算/无 X 场景按需走 libmali
#      切开关后建议 INCREMENTAL=1 增量跑，只会重跑 GPU 阶段。
#
#  收紧权限（不用 --privileged，适合共享机器）：
#      EXTRA_RUN_ARGS='--cap-add SYS_ADMIN --cap-add SYS_CHROOT --cap-add MKNOD \
#        --cap-add DAC_OVERRIDE --cap-add FOWNER \
#        --security-opt seccomp=unconfined --security-opt apparmor=unconfined' \
#        REBUILD=0 bash build/docker/build.sh
# =============================================================================
set -eE
trap 'echo "Error: in $0 on line $LINENO" >&2' ERR

# ------------------------------- 可调参数 -----------------------------------
IMAGE="${IMAGE:-kali-rootfs-builder}"
# PLATFORM 默认按宿主机架构自动推导，避免在 arm64 机器上误用 x86_64 镜像
# （退化成模拟运行，慢好几倍）。仍可显式覆盖：PLATFORM=linux/amd64 bash build.sh
case "$(uname -m)" in
    aarch64|arm64) DEFAULT_PLATFORM="linux/arm64" ;;
    *)             DEFAULT_PLATFORM="linux/amd64" ;;
esac
PLATFORM="${PLATFORM:-${DEFAULT_PLATFORM}}"
REBUILD="${REBUILD:-1}"
BOARD="${BOARD:-lubancat-4}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
INTERACTIVE="${INTERACTIVE:-1}"
EXTRA_RUN_ARGS="${EXTRA_RUN_ARGS:-}"
SKIP_KERNEL_CHECK="${SKIP_KERNEL_CHECK:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# GPU 驱动栈宏：none | panfork | libmali | both（详见 config/gpu-stack.conf）
# 优先级：环境变量 > config/gpu-stack.conf > none
# （conf 里写的是 "${GPU_STACK:-none}"，所以环境变量天然覆盖它）
[ -f config/gpu-stack.conf ] && . config/gpu-stack.conf
GPU_STACK="${GPU_STACK:-none}"

# ------------------------------- 前置校验 -----------------------------------
command -v docker >/dev/null 2>&1 || { echo "ERROR: 未找到 docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon 未运行（或当前用户无权限）" >&2; exit 1; }

# --- 宿主内核版本预检 ----------------------------------------------------------
#  Kali-rolling 的 systemd ≥ 260 把内核基线提到 5.10（官方 NEWS：baseline 5.10 /
#  recommended 5.14），并删除了老内核的兼容代码。内核低于基线时，chroot 内
#  apt/dpkg 的 postinst 会因 EUNATCH(49)（"Protocol driver not attached"）
#  大面积失败，构建根本跑不完。放在 docker build 之前拦住，避免白等镜像构建。
#  可用 SKIP_KERNEL_CHECK=1 跳过（不推荐，构建大概率仍会失败）。
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

if [ "${SKIP_KERNEL_CHECK}" != "1" ]; then
    case "$(kernel_grade "$(uname -r)")" in
        hard)
            cat >&2 <<EOF

ERROR: 宿主内核版本过低（$(uname -r)），Kali-rolling 的 systemd 260+ 要求内核 ≥ 5.10。

       systemd v260 起把内核基线从 5.4 提到 5.10，并删除了老内核的兼容代码。内核低于
       基线时，chroot 内 apt/dpkg 的 postinst 会大面积失败（典型：systemd-machine-id-setup
       报 EUNATCH 退出非 0 → dpkg 返回 100 → docker build 失败），构建根本跑不完。

  请选择以下出路之一：

    A. 升级宿主内核到 ≥ 5.10（推荐 ≥ 5.14，systemd 官方推荐基线）
         Ubuntu 20.04（默认 5.4）：sudo apt-get install linux-generic-hwe-20.04
         重启后用 uname -r 确认

    B. 改用已全绿的 CI 构建（ubuntu-24.04 runner，内核 6.8）
         见 .github/workflows/build-rootfs.yml，勾选 upload_artifact 可取产物

  若只想验证脚本其他部分（不推荐，构建大概率仍会失败）：
         SKIP_KERNEL_CHECK=1 bash build/docker/build.sh

EOF
            exit 1
            ;;
        soft)
            echo "提示：宿主内核 $(uname -r) 介于 5.10~5.13，低于 systemd 推荐基线 5.14，构建通常可完成但建议升级。"
            ;;
        *)
            :   # ≥ 5.14 静默通过
            ;;
    esac
fi

# binfmt 前置检查 —— 放在宿主机侧检查，比在容器里报错更早、提示更清楚。
# 仅交叉构建需要：宿主是 arm64 时执行 arm64 二进制是原生行为，不需要 qemu。
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "aarch64" ] && [ "$HOST_ARCH" != "arm64" ] \
   && [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    cat >&2 <<EOF

ERROR: 宿主机未注册 qemu-aarch64 binfmt，无法交叉构建 arm64 rootfs。
       （宿主架构 ${HOST_ARCH}，需要 qemu 用户态模拟）

  请执行以下任一种：

    A. 用官方镜像一次性注册（最简单，推荐）
         docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

    B. 安装系统包（永久生效）
         sudo apt-get install -y qemu-user qemu-user-binfmt
         sudo systemctl restart systemd-binfmt
         # 或： sudo update-binfmts --enable qemu-aarch64

       注意：新版 Debian/Kali 已删除 qemu-user-static 包（Debian #1124747），
             现在应装 qemu-user + qemu-user-binfmt。

  验证：  cat /proc/sys/fs/binfmt_misc/qemu-aarch64

EOF
    exit 1
fi

echo "==============================================================="
echo " Kali rootfs 薄容器构建"
echo "   镜像     : ${IMAGE}"
echo "   平台     : ${PLATFORM}（宿主 $(uname -m)，可覆盖 PLATFORM）"
echo "   板卡     : ${BOARD}"
echo "   GPU 栈   : ${GPU_STACK}（none|panfork|libmali|both，可覆盖 GPU_STACK）"
echo "   重建镜像 : ${REBUILD}"
echo "   强制重建 : ${FORCE_REBUILD}"
echo "   仓库     : ${REPO_ROOT}"
echo "==============================================================="

# ------------------------------- 1. 构建镜像 ---------------------------------
if [ "${REBUILD}" = "1" ]; then
    echo ""
    echo ">>> [1/2] docker build ${IMAGE}"
    docker build \
        --platform "${PLATFORM}" \
        --file Dockerfile \
        --tag "${IMAGE}" \
        .
else
    docker image inspect "${IMAGE}" >/dev/null 2>&1 || {
        echo "ERROR: 镜像 ${IMAGE} 不存在，请先不带 REBUILD=0 运行一次" >&2; exit 1
    }
    echo ""
    echo ">>> [1/2] 跳过镜像构建（REBUILD=0），复用 ${IMAGE}"
fi

# ------------------------------- 2. 运行容器 ---------------------------------
echo ""
echo ">>> [2/2] 运行容器（仓库挂载，产物直接落宿主 build/）"
mkdir -p build

# -it  : 给一个 TTY。debootstrap/apt 在极少数情况下会尝试读 TTY，
#        虽然已设 DEBIAN_FRONTEND=noninteractive，给 TTY 更保险。
#        CI 环境请设 INTERACTIVE=0。
TTY_ARGS=()
[ "${INTERACTIVE}" = "1" ] && TTY_ARGS=(-it)

docker run --rm \
    "${TTY_ARGS[@]}" \
    --privileged \
    ${EXTRA_RUN_ARGS} \
    -v "${REPO_ROOT}":/work/kali-rootfs \
    -w /work/kali-rootfs \
    -e BOARD="${BOARD}" \
    -e FORCE_REBUILD="${FORCE_REBUILD}" \
    -e SKIP_KERNEL_CHECK="${SKIP_KERNEL_CHECK}" \
    -e GPU_STACK="${GPU_STACK}" \
    "${IMAGE}"

# ------------------------------- 3. 汇报产物 ---------------------------------
echo ""
echo "==============================================================="
echo " Done"
echo "==============================================================="
if [ -f "${REPO_ROOT}/build/rootfs.img" ]; then
    ls -lh "${REPO_ROOT}/build/rootfs.img"
    echo ""
    echo "烧写到根分区："
    echo "  sudo dd if=build/rootfs.img of=/dev/mmcblk0pX bs=1M status=progress conv=fsync"
else
    echo "ERROR: build/rootfs.img 不存在" >&2
    exit 1
fi
echo ""
echo "提示：下次想跳过 rootfs 构建直接重打包 img："
echo "      FORCE_REBUILD=0 REBUILD=0 bash build/docker/build.sh"
