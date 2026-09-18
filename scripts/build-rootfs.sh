#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

SELF_PATH="$(readlink -f -- "$0")"
cd "$(dirname -- "${SELF_PATH}")" && cd ..
mkdir -p build && cd build

# ── 构建模式开关（不设置时行为与旧版完全一致：不是全量就是跳过）──────────
#   INCREMENTAL=1    增量：复用 build/rootfs 里已完成的重型阶段
#                    （debootstrap / apt / swapfile / 自带 deb / firmware），
#                    只重跑廉价的定制阶段（overlay 拷贝、服务使能、配置覆写）。
#                    改 overlay 后几十秒即可得到新的 rootfs 目录树。
#   FORCE_REBUILD=1  忽略所有缓存与标记，从零全量重建（含删掉状态目录）。
#   APT_REFRESH=1    增量模式下仍强制重跑 apt 阶段（想拉最新软件包时用）。
#   命令行等价写法：--incremental / --force / --apt-refresh / --help
#
#   状态目录 build/.build-state/ 只记录"哪些阶段已完成 + 输入指纹"：
#     删掉它 = 回到全量重建；改包列表 / 镜像源会自动让对应阶段失效重跑。
for _arg in "$@"; do
        case "$_arg" in
                --incremental) INCREMENTAL=1 ;;
                --force|--full) FORCE_REBUILD=1 ;;
                --apt-refresh) APT_REFRESH=1 ;;
                -h|--help)
                        echo "Usage: $0 [--incremental|--force|--apt-refresh]"
                        echo "  --incremental  复用 build/rootfs 已完成的重型阶段，只重跑定制阶段"
                        echo "  --force        删除所有缓存与标记，从零全量重建"
                        echo "  --apt-refresh  增量模式下强制重跑 apt 阶段"
                        echo "  等价环境变量: INCREMENTAL=1 / FORCE_REBUILD=1 / APT_REFRESH=1"
                        exit 0
                        ;;
                *) echo "Unknown option: $_arg (try --help)"; exit 1 ;;
        esac
done
INCREMENTAL="${INCREMENTAL:-0}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
APT_REFRESH="${APT_REFRESH:-0}"
STATE_DIR=".build-state"
STAGE_DIR="${STATE_DIR}/stages"

# 阶段标记与指纹：done 表示该阶段跑完，fp 记录当时的输入，输入变了就自动失效
stage_done()  { [ -f "${STAGE_DIR}/$1.done" ]; }
stage_fp_ok() { [ -f "${STAGE_DIR}/$1.fp" ] && [ "$(cat "${STAGE_DIR}/$1.fp")" = "$2" ]; }
stage_mark()  { mkdir -p "${STAGE_DIR}"; touch "${STAGE_DIR}/$1.done"; printf '%s' "$2" > "${STAGE_DIR}/$1.fp"; }
fp_of()       { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
mode_of()     { if [[ ${INCREMENTAL} == 1 ]]; then echo "[增量]"; else echo "[全量]"; fi; }


# 断点续传：mk-image.sh 的产物 rootfs.img 已存在则跳过整套构建。
# 需要强制重建时：rm -f build/rootfs.img（或删掉整个 build/ 目录）后重跑。
# 增量模式（INCREMENTAL=1）下不短路 —— 否则"改完 overlay 再打包"这条最快的路走不通。
if [[ -f rootfs.img && ${INCREMENTAL} != 1 && ${FORCE_REBUILD} != 1 ]]; then
        echo "rootfs.img already exists, skipping build."
        echo "  强制全量重建 : FORCE_REBUILD=1 $0      （或 rm -f build/rootfs.img）"
        echo "  增量更新     : INCREMENTAL=1 $0"
        exit 0
fi
echo "$(mode_of) 构建模式: INCREMENTAL=${INCREMENTAL} FORCE_REBUILD=${FORCE_REBUILD} APT_REFRESH=${APT_REFRESH}"


# These env vars can cause issues with chroot
unset TMP
unset TEMP
unset TMPDIR

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

# Debootstrap options
SERVER_ONLY=Y
DESKTOP_ONLY=N
arch=arm64
release=kali-rolling
#mirror=https://old.kali.org/kali/dists
mirror=https://mirrors.aliyun.com/kali/
# mirror=https://mirrors.ustc.edu.cn/ubuntu-ports/
chroot_dir=rootfs
overlay_dir=../overlay
firmware_dir=../overlay-firmware

# ── 阶段 1：基础系统（debootstrap）───────────────────────────────────────
# 复用条件（全部满足才跳过）：目录存在且完整 + 有完成标记 + arch/release/mirror 未变。
# 任一不满足 → 删掉 chroot 与全部状态，从头 debootstrap（即旧版默认行为）。
BOOTSTRAP_FP="$(fp_of "arch=${arch} release=${release} mirror=${mirror}")"
REBUILD_REASON=""
if [[ ${FORCE_REBUILD} == 1 ]]; then
        REBUILD_REASON="FORCE_REBUILD=1"
elif [[ ! -d ${chroot_dir} ]]; then
        REBUILD_REASON="chroot 目录不存在"
elif [[ ! -x ${chroot_dir}/usr/bin/apt-get || ! -f ${chroot_dir}/etc/os-release ]]; then
        REBUILD_REASON="chroot 目录不完整（缺 apt-get 或 os-release）"
elif ! stage_done debootstrap; then
        REBUILD_REASON="上次 debootstrap 未完成（无完成标记）"
elif ! stage_fp_ok debootstrap "${BOOTSTRAP_FP}"; then
        REBUILD_REASON="debootstrap 参数已变化（arch/release/mirror）"
fi

# Clean chroot dir and make sure folder is not mounted
# 无论增量与否都先清残留挂载，否则 rm -rf 会失败
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

NEED_BOOTSTRAP=0
if [[ -n ${REBUILD_REASON} ]]; then
        NEED_BOOTSTRAP=1
        echo "$(mode_of) 重建基础系统：${REBUILD_REASON}"
        rm -rf ${chroot_dir} ${STATE_DIR}
        mkdir -p ${chroot_dir} ${STAGE_DIR}
else
        echo "$(mode_of) 复用已有基础系统 ${chroot_dir}，跳过 debootstrap"
fi

# Install the base system into a directory 
if [[ ${NEED_BOOTSTRAP} == 1 ]]; then
        if [ -f /usr/bin/qemu-aarch64-static ]; then
                # Run debootstrap with --foreign and copy qemu-aarch64-static
                # for cross compile with x86_64 machine, we need sure that /usr/bin/qemu-aarch64-static has been downloaded
                debootstrap --foreign --arch ${arch} ${release} ${chroot_dir} ${mirror}
                sudo cp /usr/bin/qemu-aarch64-static ${chroot_dir}/usr/bin/
                chroot ${chroot_dir} /debootstrap/debootstrap --second-stage
        else
                # Run debootstrap without --foreign
                debootstrap --arch "${arch}" "${release}" "${chroot_dir}" "${mirror}"
        fi
        stage_mark debootstrap "${BOOTSTRAP_FP}"
fi

# Use a more complete sources.list file 
cat > ${chroot_dir}/etc/apt/sources.list << EOF

deb ${mirror} ${release} main non-free contrib
#  deb-src ${mirror} ${release} main non-free contrib
EOF

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Package priority for ppa
cp ${overlay_dir}/etc/apt/preferences.d/rockchip-ppa ${chroot_dir}/etc/apt/preferences.d/rockchip-ppa
cp ${overlay_dir}/etc/apt/preferences.d/panfork-mesa-ppa ${chroot_dir}/etc/apt/preferences.d/panfork-mesa-ppa
cp ${overlay_dir}/etc/apt/preferences.d/rockchip-multimedia-ppa ${chroot_dir}/etc/apt/preferences.d/rockchip-multimedia-ppa

# ── 阶段 2：APT 包安装（重型，按 apt 段落自身的源码指纹跳过）──────────────
# 指纹直接取自本脚本中 apt 段落的原文：增删任何包 / 换源 / 改移除列表，
# 指纹都会变化并自动触发重跑，不需要在别处再维护一份包列表副本。
APT_SRC="$(sed -n '/^# Download and update packages$/,/^EOF$/p' "${SELF_PATH}" 2>/dev/null || true)"
if [[ -z ${APT_SRC} ]]; then
        # 读不到自身源码（例如通过管道执行）→ 用随机值，确保每次都重跑
        APT_SRC="$(date +%s%N) $(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
fi
APT_FP="$(fp_of "${APT_SRC}")"
APT_SKIP=0
rm -f ${chroot_dir}/.apt-skip
if [[ ${APT_REFRESH} != 1 ]] && stage_done apt && stage_fp_ok apt "${APT_FP}"; then
        APT_SKIP=1
        touch ${chroot_dir}/.apt-skip
        echo "$(mode_of) 跳过 APT 阶段（包列表与源均未变；要拉最新包请加 APT_REFRESH=1）"
fi

# Download and update packages
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR


HOST=lubancat

# Create User（幂等：增量重跑时不能因 useradd 报错而中断）
id -u cat >/dev/null 2>&1 || useradd -G sudo -m -s /bin/bash cat
passwd cat <<IEOF
temppwd
temppwd
IEOF
gpasswd -a cat video || true
gpasswd -a cat audio || true
passwd root <<IEOF
root
root
IEOF

# allow root login
sed -i '/pam_securetty.so/s/^/# /g' /etc/pam.d/login

# hostname
echo lubancat > /etc/hostname

# set localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# Add mesa and rockchip multimedia ppa

# apt-get -y update && apt-get -y install software-properties-common
# add-apt-repository -y ppa:liujianfeng1994/panfork-mesa
# add-apt-repository -y ppa:liujianfeng1994/rockchip-multimedia


# Download and update installed packages（增量模式下整段可跳过）
if [ ! -e /.apt-skip ]; then
echo "[apt] update / upgrade / dist-upgrade ..."
apt-get -y update && apt-get -y upgrade && apt-get -y dist-upgrade

# Download and install generic packages
apt-get -y install dmidecode mtd-tools i2c-tools u-boot-tools  \
bash-completion man-db manpages nano gnupg initramfs-tools python3-dev tree \
  dosfstools mtools parted ntfs-3g zip atop \
p7zip-full htop iotop pciutils lshw lsof  exfat-fuse hwinfo \
net-tools wireless-tools openssh-client openssh-server wpasupplicant ifupdown \
pigz wget curl lm-sensors bluez gdisk usb-modeswitch usb-modeswitch-data make \
gcc libc6-dev bison libssl-dev flex fake-hwclock rfkill wireless-regdb mmc-utils \
network-manager python3-opencv python3-pip python3-numpy python3-venv \
bc cloud-guest-utils cloud-initramfs-growroot locales locales-all  ntpsec-ntpdate vim chrony

# Download and install kali packages
apt-get -y install kali-linux-core kali-desktop-xfce 

# Update upgrade
apt-get -y full-upgrade

# Remove cryptsetup and needrestart
apt-get -y remove cryptsetup needrestart brltty

# Clean package cache
# apt-get -y autoremove && apt-get -y clean && apt-get -y autoclean
apt-get -y autoremove && apt-get -y clean
rm -f /.apt-skip
else
echo "[apt] skipped (incremental: package list unchanged)"
fi

EOF

rm -f ${chroot_dir}/.apt-skip   # 别把这个临时标志打进镜像

if [[ ${APT_SKIP} == 1 ]]; then
        echo "$(mode_of) APT 阶段已跳过（指纹未变）"
else
        stage_mark apt "${APT_FP}"
fi

# ── 阶段 3：swapfile（幂等：存在且刚好 2GB 就跳过，省掉一次 2GB dd）──────
SWAP_BYTES="$(stat -c %s ${chroot_dir}/swapfile 2>/dev/null || echo 0)"
if [[ "${SWAP_BYTES}" == "2147483648" ]]; then
        echo "$(mode_of) swapfile 已存在（2GB），跳过"
else
# Swapfile
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

dd if=/dev/zero of=/tmp/swapfile bs=1024 count=2097152
chmod 600 /tmp/swapfile
mkswap /tmp/swapfile
mv /tmp/swapfile /swapfile
EOF
fi

# ── 阶段 4：仓库自带 arm64 deb（按"文件名+大小"指纹跳过）────────────────
DEB_FP="$(fp_of "$(ls -l ../packages/arm64/*.deb 2>/dev/null | awk '{print $5, $NF}' || true)")"
if stage_done debs && stage_fp_ok debs "${DEB_FP}"; then
        echo "$(mode_of) 跳过 arm64 deb 安装（包未变化）"
else
# Install arm64 deb package
cp -r ../packages/arm64/* ${chroot_dir}/tmp
chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/*.deb || true"
rm -rf ${chroot_dir}/tmp/*
stage_mark debs "${DEB_FP}"
fi

# Customize header content
cp ${overlay_dir}/etc/update-motd.d/{00-header,30-sysinfo} ${chroot_dir}/etc/update-motd.d

# DNS
cp ${overlay_dir}/etc/resolv.conf ${chroot_dir}/etc/resolv.conf

# Hosts file
cp ${overlay_dir}/etc/hosts ${chroot_dir}/etc/hosts

# Serial console resize script
cp ${overlay_dir}/etc/profile.d/resize.sh ${chroot_dir}/etc/profile.d/resize.sh

# Enable rc-local
cp ${overlay_dir}/etc/rc.local ${chroot_dir}/etc/rc.local

# Default adduser config
cp ${overlay_dir}/etc/adduser.conf ${chroot_dir}/etc/adduser.conf

mkdir -p ${chroot_dir}/etc/initramfs/post-update.d/
cp ${overlay_dir}/etc/initramfs/post-update.d/zz-update-firmware ${chroot_dir}/etc/initramfs/post-update.d/zz-update-firmware

# Fix root filesystem issues by changing fsck -a to -y.
cp ${overlay_dir}/usr/share/initramfs-tools/scripts/functions ${chroot_dir}/usr/share/initramfs-tools/scripts/functions
sed -i 's/^FSTYPE=auto/FSTYPE=ext4/' ${chroot_dir}/etc/initramfs-tools/initramfs.conf

# Realtek 8811CU/8821CU usb modeswitch support
cp ${chroot_dir}/lib/udev/rules.d/40-usb_modeswitch.rules ${chroot_dir}/etc/udev/rules.d/40-usb_modeswitch.rules
sed '/LABEL="modeswitch_rules_end"/d' -i ${chroot_dir}/etc/udev/rules.d/40-usb_modeswitch.rules
cat >> ${chroot_dir}/etc/udev/rules.d/40-usb_modeswitch.rules <<EOF
# Realtek 8811CU/8821CU Wifi AC USB
ATTR{idVendor}=="0bda", ATTR{idProduct}=="1a2b", RUN+="/usr/sbin/usb_modeswitch -K -v 0bda -p 1a2b"

LABEL="modeswitch_rules_end"
EOF

# Add usb modeswitch to initrd this fixes a boot hang with 8811CU/8821CU
cp ${overlay_dir}/usr/share/initramfs-tools/hooks/usb_modeswitch ${chroot_dir}/usr/share/initramfs-tools/hooks/usb_modeswitch

# Set cpu governor to performance
cp ${overlay_dir}/usr/lib/systemd/system/cpu-governor-performance.service ${chroot_dir}/usr/lib/systemd/system/cpu-governor-performance.service
chroot ${chroot_dir} /bin/bash -c "systemctl enable cpu-governor-performance"

# Set gpu governor to performance
cp ${overlay_dir}/usr/lib/systemd/system/gpu-governor-performance.service ${chroot_dir}/usr/lib/systemd/system/gpu-governor-performance.service
chroot ${chroot_dir} /bin/bash -c "systemctl enable gpu-governor-performance"

# add initial service
cp ${overlay_dir}/usr/local/boot_init.sh ${chroot_dir}/usr/local
cp ${overlay_dir}/usr/local/linux-image.deb ${chroot_dir}/usr/local
chroot ${chroot_dir} /bin/bash -c "chmod +x /usr/local/boot_init.sh"


cp ${overlay_dir}/usr/lib/systemd/system/boot_init.service ${chroot_dir}/usr/lib/systemd/system/
chroot ${chroot_dir} /bin/bash -c "systemctl enable boot_init"

cp ${overlay_dir}/usr/lib/systemd/system/kernel-install.service ${chroot_dir}/usr/lib/systemd/system/
chroot ${chroot_dir} /bin/bash -c "systemctl enable kernel-install"


# Add realtek bluetooth firmware to initrd 
cp ${overlay_dir}/usr/share/initramfs-tools/hooks/rtl-bt ${chroot_dir}/usr/share/initramfs-tools/hooks/rtl-bt

# Service to synchronise system clock to hardware RTC
cp ${overlay_dir}/usr/lib/systemd/system/rtc-hym8563.service ${chroot_dir}/usr/lib/systemd/system/rtc-hym8563.service

# Modify service timeout
cp ${overlay_dir}/usr/lib/systemd/system/NetworkManager-wait-online.service ${chroot_dir}/usr/lib/systemd/system/NetworkManager-wait-online.service

# Set term for serial tty
mkdir -p ${chroot_dir}/lib/systemd/system/serial-getty@.service.d/
cp ${overlay_dir}/usr/lib/systemd/system/serial-getty@.service.d/10-term.conf ${chroot_dir}/usr/lib/systemd/system/serial-getty@.service.d/10-term.conf

# Fix 120 second timeout bug
mkdir -p ${chroot_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/
cp ${overlay_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf ${chroot_dir}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf

# Fix network management not being taken over
#cp ${overlay_dir}/etc/netplan/01-network-manager-all.yaml ${chroot_dir}/etc/netplan/01-network-manager-all.yaml

# Fix the problem of network interface order change
cp ${overlay_dir}/etc/udev/rules.d/80-net-setup-link.rules ${chroot_dir}/etc/udev/rules.d/80-net-setup-link.rules

# Use gzip compression for the initrd
cp ${overlay_dir}/etc/initramfs-tools/conf.d/compression.conf ${chroot_dir}/etc/initramfs-tools/conf.d/compression.conf

# Disable terminal ads
# sed -i 's/ENABLED=1/ENABLED=0/g' ${chroot_dir}/etc/default/motd-news
# chroot ${chroot_dir} /bin/bash -c "pro config set apt_news=false"

# Remove release upgrade motd
# rm -f ${chroot_dir}/var/lib/ubuntu-release-upgrader/release-upgrade-available
# cp ${overlay_dir}/etc/update-manager/release-upgrades ${chroot_dir}/etc/update-manager/release-upgrades

# Copy over the ubuntu rockchip install util
cp ${overlay_dir}/usr/bin/ubuntu-rockchip-install ${chroot_dir}/usr/bin/ubuntu-rockchip-install

# Let systemd create machine id on first boot
rm -f ${chroot_dir}/var/lib/dbus/machine-id
true > ${chroot_dir}/etc/machine-id

# configure the default apps
cat >> ${chroot_dir}/etc/profile<< EOF

export PATH=$PATH:/sbin
export PATH=$PATH:/bin

EOF

# # configure /boot
# cat >> ${chroot_dir}/etc/fstab<< EOF

# /dev/mmcblk0p2  /boot           auto    defaults        0       2

# EOF

#add wifi firmware 
# ── 阶段 5：WiFi/BT firmware（按文件清单指纹跳过）───────────────────────
FW_FP="$(fp_of "$(find ${firmware_dir}/usr/lib/firmware -type f -printf '%s %T@\n' 2>/dev/null | sort | md5sum)")"
if stage_done firmware && stage_fp_ok firmware "${FW_FP}"; then
        echo "$(mode_of) 跳过 firmware 拷贝（内容未变）"
else
        echo "$(mode_of) 拷贝 firmware -> ${chroot_dir}/usr/lib/"
        cp -r ${firmware_dir}/usr/lib/firmware ${chroot_dir}/usr/lib/
        stage_mark firmware "${FW_FP}"
fi
chroot ${chroot_dir} /bin/bash -c "ln -sf /usr/lib/firmware /lib/firmware"
# Ensure /lib/firmware points to /usr/lib/firmware (kernel firmware search path fix)
#chroot ${chroot_dir} /bin/bash -c "if [ ! -L /lib/firmware ]; then rm -rf /lib/firmware && ln -s /usr/lib/firmware /lib/firmware; fi"

#enable ntp 
cp ${overlay_dir}/etc/chrony/chrony.conf ${chroot_dir}/etc/chrony/
chroot ${chroot_dir} /bin/bash -c "systemctl enable chrony"


# configure ssh
chroot ${chroot_dir} /bin/bash -c "systemctl enable ssh"


# Umount temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

if [[ ${INCREMENTAL} == 1 ]]; then
        echo ""
        echo "[增量] rootfs 目录树已更新：build/rootfs/"
        echo "       已完成阶段：$(ls ${STAGE_DIR} 2>/dev/null | tr '\n' ' ')"
        echo "       注意：build/rootfs.img 还是旧内容，需要重新打包才会生效："
        echo "         cd build && bash mk-image.sh rootfs && bash mk-updateimg.sh rk3588 emmc"
fi

# Tar the entire rootfs
# [[ ${DESKTOP_ONLY} != "Y" ]] && cd ${chroot_dir} && XZ_OPT="-3 -T0" tar -cpJf ../ubuntu-22.04-server-arm64.rootfs.tar.xz . && cd ..
[[ ${SERVER_ONLY} == "Y" ]] && exit 0

