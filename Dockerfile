# syntax=docker/dockerfile:1.7
# =============================================================================
#  Kali Rootfs Builder — 薄容器（thin container）
# =============================================================================
#  设计原则：**镜像内不含任何构建逻辑**。
#
#  这个镜像只做一件事：提供一个装好全部依赖的 kali-rolling 环境。
#  真正的构建由仓库里的两个既有脚本完成，容器原封不动地调用它们：
#
#      scripts/build-rootfs.sh   ->  生成 build/rootfs/ 目录树
#      build/mk-image.sh         ->  打包成 build/rootfs.img
#
#  使用方法（详见 build/docker/README.md）：
#      bash build/docker/build.sh
#
#  仓库通过 -v 挂载进容器，所以：
#    * 改脚本不需要重建镜像；
#    * 产物（rootfs 5~10GB + rootfs.img 5~8GB）零拷贝直接落在宿主磁盘，
#      不经过 docker daemon，也不需要 docker cp。
# =============================================================================
FROM kalilinux/kali-rolling

# 构建期禁止一切交互式提问。
# debootstrap 与 chroot 内的 apt/dpkg 在缺少这两个变量时会挂起等待输入。
ENV DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1

# -----------------------------------------------------------------------------
#  依赖清单
# -----------------------------------------------------------------------------
#  这份清单是从「既有的两个脚本实际调用了什么」反推出来的，
#  而不是照抄 README —— README 那份是从 Ubuntu 项目继承来的，有失效项。
#
#  按用途分组：
#    debootstrap              第 50/55 行：生成 kali-rolling 基础系统
#    qemu-user-static        仅 x86_64 需要！见下方 ARCH 条件安装说明
#    util-linux / mount      第 67-70、290-291 行：mount / umount / findmnt
#    e2fsprogs               mk-image.sh 第 26/29/30 行：mkfs.ext4/e2fsck/resize2fs
#    sudo                    mk-image.sh 第 20/21/26/29/30 行共 5 处调用
#                            （容器内以 root 运行，sudo cmd 等价于直接执行）
#    coreutils/findutils     mk-image.sh 第 20/21 行：du / find / wc
#    tar/gzip/xz/zstd/pigz   归档与压缩
#    build-essential + gcc-aarch64-linux-gnu  交叉编译
#    bison/flex/bc/libssl-dev/libncurses-dev  内核与 u-boot 构建依赖
#    u-boot-tools            mkimage
#    device-tree-compiler    dtc
#    rsync/kmod/cpio/fakeroot/fakechroot      initramfs 与 rootfs 操作
#    parted/fdisk/dosfstools/mtools           分区与 FAT 操作
#    udev/uuid-runtime       uuidgen 等
#    python3/python-is-python3                部分工具脚本依赖
#
#  刻意不装的项：
#    * python2 —— README 里列了它，但 kali-rolling 早已移除该包，
#      照抄会让 apt-get install 直接失败。这是必须注意的差异。
#    * binfmt-support / qemu-user-binfmt —— 这两个包靠 systemd 服务注册 binfmt，
#      但 docker build 阶段服务不会启动（日志里可见 policy-rc.d denied），
#      在本方案里从未生效，纯属无用依赖。
#
#  ★ qemu-user-static 为什么按架构条件安装：
#      build-rootfs.sh 第 50 行用 `[ -f /usr/bin/qemu-aarch64-static ]` 分流：
#        x86_64 容器 → 装了 amd64 版 qemu-user-static，该文件存在 → 走交叉构建
#        arm64  容器 → 装的是 arm64 版，**不提供** qemu-aarch64-static
#                      → 自动走原生 debootstrap，不需要 qemu
#      在 arm64 上强装还会白拉 63.8MB 的 arm64 qemu-user（日志 Get:149 可见）。
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        debootstrap \
        util-linux mount e2fsprogs sudo \
        coreutils findutils tar gzip xz-utils zstd pigz \
        build-essential gcc-aarch64-linux-gnu \
        bison flex bc libssl-dev libncurses-dev \
        u-boot-tools device-tree-compiler \
        rsync kmod cpio fakeroot fakechroot \
        parted fdisk dosfstools mtools \
        udev uuid-runtime git git-lfs \
        python3 python3-minimal python-is-python3 \
        wget curl ca-certificates file procps; \
    if [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "amd64" ]; then \
        echo ">>> x86_64 宿主：安装 qemu-user-static（交叉构建 arm64 所需）"; \
        apt-get install -y --no-install-recommends qemu-user-static; \
    else \
        echo ">>> $(uname -m) 宿主：原生执行，跳过 qemu-user-static（省 60MB+）"; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

# -----------------------------------------------------------------------------
#  入口脚本
# -----------------------------------------------------------------------------
#  唯一职责是「环境自检 + 调用原脚本 + 容器适配清理」：
#    1) 检查 root 权限、仓库挂载、qemu binfmt 是否就绪
#    2) 调用 scripts/build-rootfs.sh
#    3) 清理 rootfs 下的挂载残留（防止宿主 /dev 被灌进 img）
#    4) 补调 config_image_hook__<board>（build-rootfs.sh 本身不调用它）
#    5) 删除构建期专用的 qemu-aarch64-static
#    6) 调用 build/mk-image.sh 并处理 e2fsck 返回码陷阱
# -----------------------------------------------------------------------------
COPY build/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work/kali-rootfs

# 用 ENTRYPOINT 而不是 CMD：运行容器时无需重复传参，
# 且入口脚本里的环境自检一定会执行。
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
