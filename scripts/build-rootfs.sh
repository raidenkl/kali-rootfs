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
                        echo ""
                        echo "  GPU 驱动栈宏（可选，默认 none）："
                        echo "    GPU_STACK=none     不装，Kali 官方 Mesa（GL 走 llvmpipe 软渲染）"
                        echo "    GPU_STACK=panfork  装 panfork mesa（X11 桌面 GL/glamor 硬件加速）"
                        echo "    GPU_STACK=libmali  装 Rockchip 闭源 libmali（GLES/OpenCL/Vulkan/GBM）"
                        echo "    GPU_STACK=both     两者都装（推荐）"
                        echo "    默认值来自 config/gpu-stack.conf，环境变量优先"
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

# ── GPU 用户态驱动栈开关（宏）────────────────────────────────────────────
#   none | panfork | libmali | both      —— 语义见 config/gpu-stack.conf
#   优先级：环境变量 > config/gpu-stack.conf > none
#   （conf 文件里写的是 "${GPU_STACK:-none}"，所以环境变量天然覆盖它）
[ -f ../config/gpu-stack.conf ] && . ../config/gpu-stack.conf
GPU_STACK="${GPU_STACK:-none}"
case "${GPU_STACK}" in
        none|panfork|libmali|both) ;;
        *) echo "GPU_STACK=${GPU_STACK} 无效（可选 none|panfork|libmali|both）"; exit 1 ;;
esac
export GPU_STACK    # chroot 子进程要读它（chroot 继承环境）
echo "$(mode_of) GPU 驱动栈: GPU_STACK=${GPU_STACK}"

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

# ── 阶段 2.5：GPU 用户态驱动栈（可选，由 GPU_STACK 宏控制）───────────────
# 为什么需要这一阶段：本板内核走 Arm kbase 闭源 DDK（/dev/mali0），而 Kali 自带
# Mesa 26 里的 panfrost/panthor 只认主线 panthor 驱动 —— 配不上 kbase，GL 会静默
# 回退到 llvmpipe（全程 CPU 软渲染）。要拿到硬件加速只有两条路，本阶段把它们
# 做成 GPU_STACK 开关（none | panfork | libmali | both）。
#
#   panfork：第三方 PPA 上的 mesa 23 fork，唯一能提供 X11 桌面 GL（glamor/GLX）。
#   libmali：Rockchip 官方闭源 blob，提供 GLES/EGL/Vulkan/OpenCL 与无 X 的 GBM 直出。
#
# 两个必须避开的坑（都踩过，有日志实证）：
#   ① libmali 的 deb 会写 /etc/ld.so.conf.d/00-aarch64-mali.conf 把 mali 目录插到
#      全局搜索最前。这会让 Xorg 也加载 libmali 的 libEGL/libgbm → glamor 的 glyph
#      着色器需要 GL_EXT_blend_func_extended（libmali 不支持）→ GLSL compile failure
#      → Xorg fatal → lightdm 重启死循环 + HDMI 狂刷 "use tmds mode"、桌面黑屏。
#      所以本阶段装完必须把它注释掉，libmali 只按需用 LD_LIBRARY_PATH 启用。
#   ② panfork 的 mesa 硬依赖 mali-g610-firmware，而那个包的 set-mali-firmware.service
#      只认 g15p0/g17p0/g18p0，本内核是 g25p0 → 落到 * 分支，把 g15p0 的固件链到
#      /lib/firmware/mali_csffw.bin（错版）。本内核的 CSF 固件其实是内嵌的，用不到
#      它，所以 mask 掉该 service 并清掉它建的软链。
GPU_DEB_LIST="$(ls -l ../packages/gpu/*.deb 2>/dev/null | awk '{print $5, $NF}' || true)"
GPU_FP="$(fp_of "stack=${GPU_STACK} libmali_deb=[${GPU_DEB_LIST}]")"
if [[ ${GPU_STACK} == "none" ]]; then
        echo "$(mode_of) GPU_STACK=none，跳过 GPU 用户态驱动栈（保持 Kali 官方 Mesa）"
elif stage_done gpu && stage_fp_ok gpu "${GPU_FP}"; then
        echo "$(mode_of) 跳过 GPU 驱动栈阶段（GPU_STACK=${GPU_STACK} 与上次相同）"
else
        # panfork 分支的输入：PPA 公钥（仓库预置，不在构建期联网抓 key）
        if [[ ${GPU_STACK} == "panfork" || ${GPU_STACK} == "both" ]]; then
                mkdir -p ${chroot_dir}/usr/share/keyrings
                cp ${overlay_dir}/usr/share/keyrings/panfork-mesa-archive-keyring.asc \
                   ${chroot_dir}/usr/share/keyrings/panfork-mesa-archive-keyring.asc
                # 源文件在 chroot 内生成（用不着放进 overlay，否则 GPU_STACK=none 也会带进镜像）
                cat > ${chroot_dir}/etc/apt/sources.list.d/panfork.sources <<'PEOF'
Types: deb
URIs: https://ppa.launchpadcontent.net/liujianfeng1994/panfork-mesa/ubuntu
Suites: jammy
Components: main
Architectures: arm64
Signed-By: /usr/share/keyrings/panfork-mesa-archive-keyring.gpg
PEOF
        fi
        # libmali 分支的输入：本地 deb 拷进 chroot 的临时目录（装完删掉，不进镜像）
        if [[ ${GPU_STACK} == "libmali" || ${GPU_STACK} == "both" ]]; then
                if [[ -n ${GPU_DEB_LIST} ]]; then
                        # 硬断言：这里只允许放【一份】提供 libmali 的 deb。
                        # 两份会导致系统出现两个 OpenCL 平台、两份 blob（各约 40~57MB），
                        # 程序按平台序号选，可能选到不同版本的 blob —— 排查起来极费劲
                        # （board 上手工装过 libmali-g610-x11 + Rockchip g24p0 deb，就是这个下场）。
                        # 注：本包与 Rockchip 那份都声明 Conflicts/Replaces: libmali，dpkg 层面
                        # 本就互斥，所以这里做构建期拦截而不是等 dpkg 报冲突。
                        GPU_NLIB=0
                        for _d in ../packages/gpu/*.deb; do
                                [[ -e ${_d} ]] || continue
                                if dpkg-deb -f "${_d}" Package Provides 2>/dev/null | grep -qiE 'libmali'; then
                                        GPU_NLIB=$((GPU_NLIB + 1))
                                        echo "    候选 libmali 包: $(basename -- "${_d}")"
                                fi
                        done
                        if [[ ${GPU_NLIB} -gt 1 ]]; then
                                echo "!! packages/gpu/ 下有 ${GPU_NLIB} 个提供 libmali 的 deb —— 拒绝构建"
                                echo "   两份 blob 会让镜像出现两个 OpenCL 平台、程序可能选到不同版本。"
                                echo "   请只保留一份（取舍依据见 packages/gpu/README.md）后重试。"
                                exit 1
                        fi
                        mkdir -p ${chroot_dir}/tmp/gpu
                        cp -f ../packages/gpu/*.deb ${chroot_dir}/tmp/gpu/
                        echo "$(mode_of) libmali 源包: $(basename -a ../packages/gpu/*.deb 2>/dev/null | tr '\n' ' ')"
                else
                        echo "!! GPU_STACK=${GPU_STACK} 但 ../packages/gpu/ 下没有 deb —— libmali 将被跳过"
                        echo "   获取方式见 packages/gpu/README.md"
                fi
        fi

        echo "$(mode_of) 安装 GPU 驱动栈（GPU_STACK=${GPU_STACK}）..."
        cat <<'GEOF' | chroot ${chroot_dir} /bin/bash
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

STACK="${GPU_STACK}"
PKGS_MESA="libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libglapi-mesa libgbm1"

if [ "$STACK" = "panfork" ] || [ "$STACK" = "both" ]; then
	echo "[gpu] ---- panfork：注册 PPA、补 libllvm14、定向降级 mesa ----"

	# 公钥：PPA 源用 Signed-By 指向独立 keyring（不用已废弃的 apt-key）。
	# 优先 dearmor 成 .gpg；gpg 不可用则退回装甲文件。
	# 指纹 0B2F0747E3BD546820A639B68065BE1FC67AABDE = Launchpad PPA for JianFeng Liu
	if [ ! -s /usr/share/keyrings/panfork-mesa-archive-keyring.asc ]; then
		echo "[gpu] 致命：缺少 panfork 公钥 —— overlay/usr/share/keyrings/panfork-mesa-archive-keyring.asc 没被拷进来"
		exit 1
	fi
	if command -v gpg >/dev/null 2>&1; then
		gpg --dearmor -o /usr/share/keyrings/panfork-mesa-archive-keyring.gpg \
		    < /usr/share/keyrings/panfork-mesa-archive-keyring.asc 2>/dev/null \
		    || cp /usr/share/keyrings/panfork-mesa-archive-keyring.asc /usr/share/keyrings/panfork-mesa-archive-keyring.gpg
	else
		cp /usr/share/keyrings/panfork-mesa-archive-keyring.asc /usr/share/keyrings/panfork-mesa-archive-keyring.gpg
	fi

	# 1) 临时加 Ubuntu jammy ports 只为一件事：取 libllvm14。
	#    panfork 的 mesa 是 jammy 期构建（1:23.0.5-0ubuntu1~...，2022-12），硬 Depends
	#    libllvm14（只为 llvmpipe/swrast 用，panfrost 本身走 NIR 不需要），而 Kali
	#    rolling 已无此包。pin 100 = 仅在该包于其它源不可得时才采用，因此绝不会把
	#    Kali 的包换成 jammy 版；装完立刻删源与 pin，jammy 不再参与后续解析。
	cat > /etc/apt/sources.list.d/ubuntu-jammy-temp.list <<'JEOF'
deb [trusted=yes] https://mirrors.aliyun.com/ubuntu-ports jammy main universe
JEOF
	cat > /etc/apt/preferences.d/ubuntu-jammy-temp <<'JEOF'
Package: *
Pin: release n=jammy
Pin-Priority: 100
JEOF
	apt-get -y update
	apt-get -y install libllvm14
	rm -f /etc/apt/sources.list.d/ubuntu-jammy-temp.list /etc/apt/preferences.d/ubuntu-jammy-temp
	apt-get -y update

	# 2) 定向降级。PPA 版本带 epoch（1:23.0.5 在 apt 眼里比 26.1.6 新），所以这是一次
	#    "升级"，但仍显式带 --allow-downgrades，避免不同 apt 版本行为差异。
	#    只降这 5 个：DRI 驱动 + GLX/EGL/GLAPI + GBM（必须与 DRI 驱动同版本）。
	INST="$(apt-get install -s --allow-downgrades $PKGS_MESA 2>/dev/null | awk '/^Inst /{print $2}' | tr '\n' ' ')"
	echo "[gpu] 将要变更: ${INST:-（无）}"
	apt-get -y install --allow-downgrades $PKGS_MESA || echo "[gpu] 安装返回非 0，见上方输出"

	# 3) hold。PPA pin 1001 只影响"选哪个候选"，不阻止被重新解析；一次普通的
	#    apt upgrade 会把整个 mesa 家族再动一遍，所以把实际被变更的包全部 hold。
	[ -n "$INST" ] && apt-mark hold $INST >/dev/null
	apt-mark hold $PKGS_MESA >/dev/null
	apt-mark hold libllvm14 >/dev/null

	# 4) mali-g610-firmware（mesa 的硬依赖，装包时已连带装上）必须留着满足 Depends，
	#    但它的 set-mali-firmware.service 只认 g15p0/g17p0/g18p0，本内核是 g25p0 →
	#    落到 * 分支 → 把 g15p0 固件链到 /lib/firmware/mali_csffw.bin。
	#    本内核的 CSF 固件是【内嵌】的（CONFIG_MALI_CSF_INCLUDE_FW=y，内核镜像里含注册名
	#    g25p0-00eac0.mali_csffw.bin），磁盘这份永不生效；而那个 service 每次开机都会
	#    `rm -f` 该路径再建软链 —— 连 Rockchip libmali deb 装进去的真文件都会被它顶掉。
	#    所以：disable + mask 它，并清掉它留下的错版软链。
	systemctl disable set-mali-firmware.service >/dev/null 2>&1 || true
	systemctl mask    set-mali-firmware.service >/dev/null 2>&1 || true

	# 只删"指向 mali_csffw_g1*p0 的软链"。若该路径是别的包装进去的真文件
	# （例如 libmali 分支那份 Rockchip 固件），一律不动 —— 那是合法产物。
	for FW in /lib/firmware/mali_csffw.bin /usr/lib/firmware/mali_csffw.bin; do
		if [ -L "$FW" ]; then
			tgt="$(readlink "$FW")"
			case "$tgt" in
				*mali_csffw_g1*p0*)
					rm -f "$FW"; echo "[gpu] 已清掉错版固件软链: $FW -> $tgt" ;;
				*)
					echo "[gpu] 保留固件软链（非 g1*p0 错版）: $FW -> $tgt" ;;
			esac
		fi
	done

	# 5) 自证：mesa 必须真的来自 panfork。装不上时不静默通过 —— 否则镜像会"看起来
	#    有 GPU 驱动"，实际仍走 llvmpipe，问题要到板卡上才发现。
	V="$(dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || true)"
	case "$V" in
		*panfork*) echo "[gpu] panfork mesa 就位: libgl1-mesa-dri $V" ;;
		*)         echo "[gpu] !! 警告：libgl1-mesa-dri 仍是 ${V:-（未安装）}（不含 panfork）—— 降级没成功，桌面仍会走 llvmpipe，检查上方 apt 输出" ;;
	esac
	dpkg-query -W -f='[gpu]   ${Package} ${Version}\n' $PKGS_MESA 2>/dev/null || true
fi

if [ "$STACK" = "libmali" ] || [ "$STACK" = "both" ]; then
	echo "[gpu] ---- libmali：安装 Rockchip 闭源用户态 ----"
	shopt -s nullglob
	debs=(/tmp/gpu/*.deb)
	shopt -u nullglob
	if [ ${#debs[@]} -eq 0 ]; then
		echo "[gpu] /tmp/gpu 下没有 deb，跳过 libmali（见 packages/gpu/README.md）"
	else
		apt-get -y install "${debs[@]}" || dpkg -i "${debs[@]}" || true
		apt-get -y -f install || true
	fi

	# ★ 关键：摘掉全局库注入。装着它 = 每台板子开机就进 Xorg 崩溃循环（见阶段注释）。
	if [ -f /etc/ld.so.conf.d/00-aarch64-mali.conf ]; then
		sed -i 's|^[[:space:]]*[^#].*|# &   # disabled by build-rootfs.sh (GPU_STACK)|' \
		    /etc/ld.so.conf.d/00-aarch64-mali.conf
		echo "[gpu] 已摘掉全局注入: /etc/ld.so.conf.d/00-aarch64-mali.conf"
	fi
	ldconfig

	# 让计算通路（OpenCL/Vulkan）免设置可用：ICD 文件里写的是裸库名 libMali*.so.1，
	# 而 mali 目录不在默认搜索路径 → 在标准目录建两个软链即可。这两个名字唯一，
	# Xorg 不会加载它们，所以安全、可逆（rm 掉软链 + ldconfig 即恢复）。
	for l in libMaliOpenCL.so.1 libMaliVulkan.so.1; do
		if [ -e "/usr/lib/aarch64-linux-gnu/mali/$l" ]; then
			ln -sf "/usr/lib/aarch64-linux-gnu/mali/$l" "/usr/lib/aarch64-linux-gnu/$l"
		fi
	done
	ldconfig

	echo "[gpu] ld.so 实际命中（默认路径应指向系统目录，绝不能是 mali/）:"
	for l in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
		p="$(ldconfig -p 2>/dev/null | awk -v L="$l" '$1==L{print $NF; exit}')"
		echo "[gpu]   $l -> ${p:-（无）}"
	done
	# 自证：实体 blob 必须在（>5MB 的那份才是真 blob，hook 只有十几 KB）
	if find /usr/lib/aarch64-linux-gnu -maxdepth 2 -name 'libmali*.so*' -size +5M 2>/dev/null | grep -q .; then
		echo "[gpu] libmali 实体 blob 已就位"
	else
		echo "[gpu] !! 警告：没找到 >5MB 的 libmali 实体库 —— 安装可能失败，检查上方 apt/dpkg 输出"
	fi
fi

rm -rf /tmp/gpu
echo "[gpu] GPU_STACK=${STACK} 处理完成"
GEOF
        rm -rf ${chroot_dir}/tmp/gpu

        # ── GPU 阶段自证：致命项中止构建，固件/卫生类只告警 ──────────────────
        # 口径：会导致"桌面起不来 / 驱动不可用"的 → FATAL（exit 1）；
        #       惰性问题（错版固件软链、mask 未生效）→ WARN，因为本内核固件是内嵌的。
        # 注意外层是 set -eE + ERR trap：所有判断都写在 if/case 条件里，别让
        # 失败的 grep/find 直接逃逸成脚本中断。
        GPU_FATAL=0
        fatal() { echo "[gpu][FATAL] $*"; GPU_FATAL=1; }

        if [[ ${GPU_STACK} == "panfork" || ${GPU_STACK} == "both" ]]; then
                GPU_VER="$(chroot ${chroot_dir} dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || true)"
                case "${GPU_VER}" in
                        *panfork*) echo "[gpu][OK]   libgl1-mesa-dri = ${GPU_VER}" ;;
                        *) fatal "libgl1-mesa-dri 未降级（=${GPU_VER:-未安装}）→ 桌面仍会走 llvmpipe" ;;
                esac
        fi
        if [[ ${GPU_STACK} == "libmali" || ${GPU_STACK} == "both" ]]; then
                if find ${chroot_dir}/usr/lib/aarch64-linux-gnu -maxdepth 2 -name 'libmali*.so*' -size +5M 2>/dev/null | grep -q .; then
                        echo "[gpu][OK]   libmali 实体 blob 已就位"
                else
                        fatal "缺 >5MB 的 libmali 实体库（只有 hook 不够，GLES 仍会归 Mesa）"
                fi
                if grep -qE '^[[:space:]]*[^#]' ${chroot_dir}/etc/ld.so.conf.d/00-aarch64-mali.conf 2>/dev/null; then
                        fatal "全局库注入仍生效（00-aarch64-mali.conf 有未注释行）→ Xorg 会 fatal"
                else
                        echo "[gpu][OK]   全局库注入已摘（00-aarch64-mali.conf 全空/全注释）"
                fi
                if chroot ${chroot_dir} ldconfig -p 2>/dev/null | awk '$1=="libEGL.so.1"{print $NF; exit}' | grep -q '/mali/'; then
                        fatal "默认 libEGL 被 mali/ 接管 → Xorg 会崩"
                else
                        echo "[gpu][OK]   默认 libEGL 指向系统目录（未被 mali/ 接管）"
                fi
        fi
        if [[ ${GPU_STACK} != "none" ]]; then
                if [[ -L ${chroot_dir}/etc/systemd/system/set-mali-firmware.service ]]; then
                        echo "[gpu][OK]   set-mali-firmware.service 已 masked"
                else
                        echo "[gpu][WARN] set-mali-firmware.service 未 masked（开机仍会 rm -f 该路径）"
                fi
                # /lib 与 /usr/lib 在 usrmerge 下是同一文件，报一次就够
                for FW in ${chroot_dir}/lib/firmware/mali_csffw.bin ${chroot_dir}/usr/lib/firmware/mali_csffw.bin; do
                        [[ -L "$FW" ]] || continue
                        FW_T="$(readlink "$FW")"
                        case "$FW_T" in
                                *mali_csffw_g1*p0*) echo "[gpu][WARN] 镜像里残留错版固件软链: $FW -> $FW_T（内嵌固件使其惰性，仅提示）" ;;
                        esac
                        break
                done
                [[ -L ${chroot_dir}/usr/lib/firmware/firmware ]] \
                        && echo "[gpu][WARN] 存在自指软链 /usr/lib/firmware/firmware（usrmerge 下的既有行为，无害）"
        fi
        if [[ ${GPU_FATAL} != 0 ]]; then
                echo ""
                echo "!! GPU 阶段自证未通过 —— 拒绝产出这样的镜像（这些不是可忽略的告警）"
                exit 1
        fi

        stage_mark gpu "${GPU_FP}"
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

# ── 日志/时钟策略（详见 build/docker/README.md「首次开机流程与日志策略」）────
# 背景：板卡无 RTC 电池，每次开机时钟被拨回 systemd 内置 epoch；跨开机的
# 持久化 journal 会触发 journald "realtime clock jumped backwards -> rotate"，
# 曾把 sysinit 卡死导致第二次开机无登录界面。故：journal 易失 + flush 超时
# 兜底 + fake-hwclock 提前恢复。（rtc-hym8563.service 已删除：其依赖的
# hwclock 镜像里不存在，且内核探测 RTC 时已自动设置系统时钟，功能重复。）
mkdir -p ${chroot_dir}/etc/systemd/journald.conf.d/
cp ${overlay_dir}/etc/systemd/journald.conf.d/10-volatile.conf ${chroot_dir}/etc/systemd/journald.conf.d/10-volatile.conf
mkdir -p ${chroot_dir}/etc/systemd/system/systemd-journal-flush.service.d/
cp ${overlay_dir}/etc/systemd/system/systemd-journal-flush.service.d/override.conf ${chroot_dir}/etc/systemd/system/systemd-journal-flush.service.d/override.conf
mkdir -p ${chroot_dir}/etc/systemd/system/fake-hwclock.service.d/
cp ${overlay_dir}/etc/systemd/system/fake-hwclock.service.d/override.conf ${chroot_dir}/etc/systemd/system/fake-hwclock.service.d/override.conf
chroot ${chroot_dir} /bin/bash -c "systemctl enable fake-hwclock.service 2>/dev/null || true"

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

# journal 已改为易失（见上方日志/时钟策略），镜像里不携带构建期的持久 journal 目录
rm -rf ${chroot_dir}/var/log/journal

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
# ⚠ 本阶段的指纹只覆盖 ${firmware_dir} 的文件清单（下一行），**不覆盖本段脚本正文**。
#   所以改了这里的命令后不会自动失效 → 必须手工清标记让它重跑：
#     rm -f build/.build-state/stages/firmware.done build/.build-state/stages/firmware.fp
FW_FP="$(fp_of "$(find ${firmware_dir}/usr/lib/firmware -type f -printf '%s %T@\n' 2>/dev/null | sort | md5sum)")"
if stage_done firmware && stage_fp_ok firmware "${FW_FP}"; then
        echo "$(mode_of) 跳过 firmware 拷贝（内容未变）"
else
        echo "$(mode_of) 拷贝 firmware -> ${chroot_dir}/usr/lib/firmware/"
        # 合并式拷贝（src/. → dst/）：GNU cp -r 在"目标目录已存在"时会把整个源目录
        # 再嵌一层（→ dst/firmware/...），而 GPU_STACK=libmali|both 装上 libmali deb 后
        # /usr/lib/firmware 一定已存在（它往那里放 mali_csffw.bin）→ 会把 WiFi/BT 固件
        # 全塞到 /usr/lib/firmware/firmware/ 里，新镜像直接掉 WiFi。
        mkdir -p ${chroot_dir}/usr/lib/firmware
        cp -r ${firmware_dir}/usr/lib/firmware/. ${chroot_dir}/usr/lib/firmware/
        stage_mark firmware "${FW_FP}"
fi
# /lib → /usr/lib 是 usrmerge 的软链，所以 /lib/firmware 通常已经"存在"；
# 无条件 ln -sf 会在它当时是真实目录时造出 /lib/firmware/firmware 这种自指软链。
chroot ${chroot_dir} /bin/bash -c "[ -e /lib/firmware ] || ln -sf /usr/lib/firmware /lib/firmware"
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

