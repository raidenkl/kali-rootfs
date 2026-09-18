#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build


# 断点续传：mk-image.sh 的产物 rootfs.img 已存在则跳过整套构建。
# 需要强制重建时：rm -f build/rootfs.img（或删掉整个 build/ 目录）后重跑。
if [[ -f rootfs.img ]]; then
        echo "rootfs.img already exists, skipping build. (rm build/rootfs.img to force rebuild)"
        exit 0
fi


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

# Clean chroot dir and make sure folder is not mounted
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true
rm -rf ${chroot_dir}
mkdir -p ${chroot_dir}

# Install the base system into a directory 
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

# Download and update packages
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR


HOST=lubancat

# Create User
useradd -G sudo -m -s /bin/bash cat
passwd cat <<IEOF
temppwd
temppwd
IEOF
gpasswd -a cat video
gpasswd -a cat audio
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


# Download and update installed packages
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
cloud-initramfs-growroot locales locales-all  ntpsec-ntpdate vim chrony

# Download and install kali packages
apt-get -y install kali-linux-core kali-desktop-xfce 

# Update upgrade
apt-get -y full-upgrade

# Remove cryptsetup and needrestart
apt-get -y remove cryptsetup needrestart brltty

# Clean package cache
# apt-get -y autoremove && apt-get -y clean && apt-get -y autoclean
apt-get -y autoremove && apt-get -y clean

EOF

# Swapfile
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

dd if=/dev/zero of=/tmp/swapfile bs=1024 count=2097152
chmod 600 /tmp/swapfile
mkswap /tmp/swapfile
mv /tmp/swapfile /swapfile
EOF

# Install arm64 deb package
cp -r ../packages/arm64/* ${chroot_dir}/tmp
chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/*.deb || true"
rm -rf ${chroot_dir}/tmp/*

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
cp -r ${firmware_dir}/usr/lib/firmware ${chroot_dir}/usr/lib/
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

# Tar the entire rootfs
# [[ ${DESKTOP_ONLY} != "Y" ]] && cd ${chroot_dir} && XZ_OPT="-3 -T0" tar -cpJf ../ubuntu-22.04-server-arm64.rootfs.tar.xz . && cd ..
[[ ${SERVER_ONLY} == "Y" ]] && exit 0

