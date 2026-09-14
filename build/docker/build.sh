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
PLATFORM="${PLATFORM:-linux/amd64}"
REBUILD="${REBUILD:-1}"
BOARD="${BOARD:-lubancat-4}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
INTERACTIVE="${INTERACTIVE:-1}"
EXTRA_RUN_ARGS="${EXTRA_RUN_ARGS:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# ------------------------------- 前置校验 -----------------------------------
command -v docker >/dev/null 2>&1 || { echo "ERROR: 未找到 docker" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon 未运行（或当前用户无权限）" >&2; exit 1; }

# binfmt 前置检查 —— 放在宿主机侧检查，比在容器里报错更早、提示更清楚。
# 仅交叉构建需要：宿主是 arm64 时执行 arm64 二进制是原生行为，不需要 qemu。
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "aarch64" ] && [ "$HOST_ARCH" != "arm64" ] \
   && [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    cat >&2 <<EOF

ERROR: 宿主机未注册 qemu-aarch64 binfmt，无法交叉构建 arm64 rootfs。
       （宿主架构 ${HOST_ARCH}，需要 qemu 用户态模拟）

  请执行以下任一种：

    A. 安装系统包（推荐）
         sudo apt-get install -y qemu-user-static binfmt-support
         sudo systemctl restart systemd-binfmt
         # 或： sudo update-binfmts --enable qemu-aarch64

    B. 用官方镜像一次性注册
         docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

  验证：  cat /proc/sys/fs/binfmt_misc/qemu-aarch64

EOF
    exit 1
fi

echo "==============================================================="
echo " Kali rootfs 薄容器构建"
echo "   镜像     : ${IMAGE}"
echo "   板卡     : ${BOARD}"
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
