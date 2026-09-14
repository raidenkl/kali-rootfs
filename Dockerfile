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
#  APT 镜像源（可用 --build-arg 覆盖）
# -----------------------------------------------------------------------------
#  基础镜像的源是 http.kali.org —— 一个 GeoIP 重定向服务，国内会被分到
#  清华/东软等教育网镜像。部分网络会被镜像站 403（IP 段屏蔽）或解析失败，
#  导致 docker build 阶段 apt-get install 直接挂掉。
#
#  默认改用阿里云源（https，走 443 不易被缓存劫持）。海外构建（如 GitHub
#  Actions）可覆盖回官方源：
#      docker build --build-arg APT_MIRROR=https://http.kali.org/kali .
#
#  注意：这层镜像里的 apt 源**只影响 docker build 阶段装依赖**；
#  rootfs 内的源由 build-rootfs.sh 第 37 行的 mirror= 变量决定（也是阿里云），
#  两者相互独立。
#
#  换源的两个细节（踩过 403 坑）：
#    1) kali-rolling 底包里没有 ca-certificates，https 源在装上它之前用不了。
#       所以第一遍 update 用 http + [trusted=yes] 保底（只装 ca-certificates，
#       面极小），第二遍再切到正式源（默认 ${APT_MIRROR}，https）。
#    2) 若覆盖 APT_MIRROR 为海外源（GitHub Actions 场景），上面两遍依旧成立，
#       http 那遍只是多花几秒。
# -----------------------------------------------------------------------------
ARG APT_MIRROR=https://mirrors.aliyun.com/kali

RUN set -eux; \
    echo "deb [trusted=yes] http://mirrors.aliyun.com/kali kali-rolling main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    echo "deb ${APT_MIRROR} kali-rolling main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list; \
    rm -rf /var/lib/apt/lists/*; \
    apt-get update

# -----------------------------------------------------------------------------
#  依赖清单
# -----------------------------------------------------------------------------
#  这份清单是从「既有的两个脚本实际调用了什么」反推出来的，
#  而不是照抄 README —— README 那份是从 Ubuntu 项目继承来的，有失效项。
#
#  按用途分组：
#    debootstrap              第 50/55 行：生成 kali-rolling 基础系统
#    qemu-user / qemu-user-binfmt   仅 x86_64 需要！见下方 ★★ 说明
#                            （注意：**不是** qemu-user-static，该包已被 Debian 删除）
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
#    * binfmt-support —— 靠 systemd 服务注册 binfmt，但 docker build 阶段
#      服务不会启动（日志里可见 policy-rc.d denied），在本方案里从未生效。
#
#  ★★ qemu 的安装：一个必须处理的上游变更（否则交叉构建静默走错分支）
#
#    build-rootfs.sh 第 50 行用 `[ -f /usr/bin/qemu-aarch64-static ]` 决定路径：
#        存在     → debootstrap --foreign + cp 进 chroot + second-stage（交叉）
#        不存在   → debootstrap --arch arm64（原生）
#
#    但这个文件名在现代 Debian/Kali 上**已经不存在了**，原因是两步上游变更：
#
#      ① Debian qemu 1:9.1.0（2024-09）把静态二进制从 qemu-user-static
#         搬到了 qemu-user（qemu-user 现在本身就是静态链接），
#         并且**去掉了 -static 后缀** —— 真正的二进制叫 /usr/bin/qemu-aarch64。
#         当时靠 qemu-user-static 这个 transitional 包提供 -static 兼容软链。
#      ② Debian bug #1124747（2026-01）**直接删除了 qemu-user-static 包**，
#         其职责由 qemu-user-binfmt 的 Provides: 承接 ——
#         于是 `apt-get install qemu-user-static` 仍能成功，却**不再创建任何
#         -static 软链**。
#
#    后果：若不处理，第 50 行判断恒为假，x86_64 上会**静默**改走原生分支，
#    与脚本作者设计的 --foreign 交叉流程不符（且 cp 那步永不执行）。
#
#    对策：装 qemu-user（现在它就是静态的），并补建 -static 别名。
#    因为是软链到**静态**二进制，语义上完全成立 —— 第 54 行 cp 进 chroot
#    也依然可用，脚本零改动。
#
#    架构差异：arm64 容器不需要 qemu（原生执行），跳过可省 60MB+。
# -----------------------------------------------------------------------------
RUN set -eux; \
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
    echo ">>> 生效的 apt 源: $(cat /etc/apt/sources.list)"; \
    if [ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "amd64" ]; then \
        echo ">>> x86_64 宿主：安装 qemu-user（静态，交叉构建 arm64 所需）"; \
        apt-get install -y --no-install-recommends qemu-user qemu-user-binfmt; \
        if [ ! -e /usr/bin/qemu-aarch64-static ]; then \
            echo ">>> 补建 /usr/bin/qemu-aarch64-static -> qemu-aarch64（见上方 ★★ 说明）"; \
            ln -sf /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static; \
        fi; \
        ls -l /usr/bin/qemu-aarch64 /usr/bin/qemu-aarch64-static || true; \
        test -x /usr/bin/qemu-aarch64-static; \
    else \
        echo ">>> $(uname -m) 宿主：原生执行，跳过 qemu（省 60MB+）"; \
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
