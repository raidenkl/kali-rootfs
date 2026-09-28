#!/bin/bash
# ============================================================================
# check-gpu.sh —— 在【板卡上】运行，逐层确认 RK3588 / Mali-G610 的 GPU 是否真的在工作
#
# 用法：
#   sudo bash check-gpu.sh            # 只做静态检查（不跑分）
#   sudo bash check-gpu.sh --bench    # 额外跑 glmark2 压力测试
#
# 分层思路（任何一层断了，后面都不用看）：
#   L1 硬件/DTS -> L2 内核驱动 -> L2.5 CSF 固件 -> L3 设备节点 -> L4 调频/状态
#   -> L5 用户态驱动库 -> L6 渲染器实测 -> L7 压测
#
# 只读脚本：不改配置、不装包。
# ============================================================================

BENCH=0
[[ "$1" == "--bench" ]] && BENCH=1

GPU_DEVFREQ=""
for p in /sys/devices/platform/fb000000.gpu/devfreq/fb000000.gpu \
         /sys/class/devfreq/fb000000.gpu; do
	[[ -d "$p" ]] && GPU_DEVFREQ="$p" && break
done

LIBA=/usr/lib/aarch64-linux-gnu
PASS=0; WARN=0; FAIL=0
ok()   { echo -e "  \e[32m[OK]\e[0m   $*"; PASS=$((PASS+1)); }
warn() { echo -e "  \e[33m[WARN]\e[0m $*"; WARN=$((WARN+1)); }
bad()  { echo -e "  \e[31m[FAIL]\e[0m $*"; FAIL=$((FAIL+1)); }
sec()  { echo; echo -e "\e[1;36m== $* ==\e[0m"; }

# ── L1 硬件 / 设备树 ────────────────────────────────────────────────────────
sec "L1 硬件与设备树"
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
echo "  板卡型号: ${MODEL}"
COMPAT="$(tr '\0' ',' < /proc/device-tree/compatible 2>/dev/null | sed 's/,$//')"
echo "  compatible: ${COMPAT}"
if [[ "$COMPAT" == *rk3588* ]]; then
	ok "识别到 RK3588 系列 SoC（GPU 为 Mali-G610 MP4）"
else
	warn "未匹配到 rk3588*，确认板卡 DTB 选择是否正确（/boot/rk-kernel.dtb 软链）"
fi

# ── L2 内核驱动（Arm kbase / 或主线 panthor）────────────────────────────────
sec "L2 内核驱动"
if dmesg 2>/dev/null | grep -qi 'Probed as mali0'; then
	ok "kbase 驱动探测成功（dmesg: Probed as mali0）"
else
	bad "dmesg 未见 'Probed as mali0' —— kbase 没起来，GPU 一定不可用"
fi

GPU_LINE="$(dmesg 2>/dev/null | grep -iE 'arch 10\.8\.6|GPU identified as' | tail -1)"
[[ -n "$GPU_LINE" ]] && ok "GPU 识别: ${GPU_LINE#*] }" \
	|| warn "未见 'GPU identified as ... arch 10.8.6'（G610 应为 arch 10.8.6）"

DDK="$(dmesg 2>/dev/null | grep -i 'Kernel DDK version' | tail -1)"
[[ -n "$DDK" ]] && ok "内核 DDK: ${DDK#*] }" || warn "未见 Kernel DDK version 行"

for pat in 'Failed to power up GPU' 'Failed to reset GPU' 'GPU fault' 'Unhandled Page fault' 'kbase.*error'; do
	if dmesg 2>/dev/null | grep -qiE "$pat"; then
		bad "dmesg 有 GPU 错误关键字: $pat"
	fi
done

if grep -qE '^(mali_kbase|panthor) ' /proc/modules 2>/dev/null; then
	ok "内核模块已加载: $(awk '/^(mali_kbase|panthor) /{print $1}' /proc/modules | tr '\n' ' ')"
elif [[ -d /sys/module/panthor || -d /sys/module/mali_kbase ]]; then
	ok "/sys/module 下有驱动条目（$(ls -d /sys/module/*mali* /sys/module/*panthor* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')）"
elif dmesg 2>/dev/null | grep -qiE 'mali .*\.gpu:|Kernel DDK version|rknpu.*npu'; then
	ok "驱动已编译进内核镜像（内建驱动不会出现在 /proc/modules，以 dmesg 为准）"
	[[ -n "$(ls -d /sys/module/*mali* /sys/module/*kbase* 2>/dev/null)" ]] \
		&& echo "  /sys/module 里与 mali 相关的条目: $(ls -d /sys/module/*mali* /sys/module/*kbase* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
else
	bad "内核里找不到 mali_kbase/panthor 的任何痕迹"
fi

# 决定用户态该用哪套驱动：上游 Mesa 的 panfrost/panthor 只能配主线 panthor
if [[ -d /sys/module/panthor ]]; then
	ok "内核走主线 panthor，可直接配 Kali 自带的 Mesa"
elif [[ -c /dev/mali0 ]] || dmesg 2>/dev/null | grep -qi 'Kernel DDK version'; then
	warn "内核走 Arm kbase（闭源 DDK）：上游 Mesa 的 panfrost 驱动【配不上】它。"\
"两条可行路线：① panfork mesa（有桌面 GL，能救 X11 glamor，但与新 DDK 有版本风险）；"\
"② Rockchip libmali（只有 GLES/EGL，桌面仍 llvmpipe，但 GLES 应用/视频/浏览器可硬加速）"
fi

# ── L2.5 CSF 固件 ───────────────────────────────────────────────────────────
# 本板 kbase 是 CSF 模式，需要 mali_csffw.bin。但本内核把它【编译进内核】了
# （CONFIG_MALI_CSF_INCLUDE_FW=y），磁盘上那份其实永远不会被读 —— 所以这里的判读
# 重点不是"文件在不在"，而是"有没有被人塞了错版、以及有没有个 service 在开机改它"。
sec "L2.5 CSF 固件"
KDK_GEN="$(dmesg 2>/dev/null | grep -i 'Kernel DDK version' | tail -1 | grep -oE 'g[0-9]+p[0-9]+' | head -1)"
KIMG=""
for k in /boot/Image-* /boot/vmlinuz-* /boot/Image; do
	[[ -f "$k" ]] && KIMG="$k" && break
done
if [[ -n "$KIMG" ]] && grep -aq 'mali_csffw' "$KIMG" 2>/dev/null; then
	ok "内核内嵌 CSF 固件（$KIMG 里含 mali_csffw）→ 磁盘上的 mali_csffw.bin 是【惰性的】，内核不读它"
else
	if [[ -n "$KIMG" ]]; then
		warn "$KIMG 里没搜到 mali_csffw —— 内核可能依赖磁盘固件（那么错版固件就会真的出问题）"
	else
		warn "找不到内核镜像（/boot/Image-* 或 vmlinuz-*），无法判断固件是否内嵌"
	fi
fi

FW=/lib/firmware/mali_csffw.bin
[[ -e /usr/lib/firmware/mali_csffw.bin ]] && FW=/usr/lib/firmware/mali_csffw.bin
if [[ -L "$FW" ]]; then
	FWT="$(readlink "$FW")"
	case "$FWT" in
		*mali_csffw_g[0-9]*p[0-9]*)
			FWV="$(echo "$FWT" | grep -oE 'g[0-9]+p[0-9]+' | head -1)"
			if [[ -n "$KDK_GEN" && "$FWV" != "$KDK_GEN" ]]; then
				warn "$FW 指向【$FWV】而内核 DDK 是 $KDK_GEN —— 错版固件残留"
				echo "  成因：mali-g610-firmware 的 set-mali-firmware.service 只认 g15p0/g17p0/g18p0，"
				echo "        本内核匹配不上 → 落 * 分支链了 g15p0。它每次开机都会 rm -f 该路径再重建这条软链，"
				echo "        连别的包装进去的真固件都会被顶掉。"
				echo "  注：CSF 固件不像 mali-so 那样「DDK 可以更高」—— 它是与内核配套发布的，要求精确配对；"
				echo "      本内核把固件内嵌了，所以磁盘这份只是残留，不影响运行。"
				echo "  收敛：sudo systemctl disable --now set-mali-firmware.service"
				echo "        sudo systemctl mask set-mali-firmware.service"
				echo "        sudo rm -f $FW"
			else
				ok "固件软链指向 $FWV，与内核 DDK 一致（但仍建议 mask 那个 service，免得它开机改文件）"
			fi
			;;
		*) ok "固件软链: $FW -> $FWT" ;;
	esac
elif [[ -f "$FW" ]]; then
	ok "固件是真文件: $FW（$(stat -c %s "$FW") B，md5=$(md5sum "$FW" | awk '{print $1}')）"
else
	if [[ -n "$KIMG" ]] && grep -aq 'mali_csffw' "$KIMG" 2>/dev/null; then
		ok "磁盘上没有 mali_csffw.bin —— 与「内核内嵌固件」完全自洽（也反证磁盘路径确实没被使用）"
	else
		warn "磁盘上没有 mali_csffw.bin，又无法确认内核是否内嵌；若 GPU 正常工作即可判定为内嵌"
	fi
fi

SW="$(systemctl is-enabled set-mali-firmware.service 2>/dev/null || true)"
case "$SW" in
	masked) ok "set-mali-firmware.service 已 masked（不会再开机改固件路径）" ;;
	"")     : ;;
	*)      warn "set-mali-firmware.service = $SW —— 每次开机都会 rm -f 并重建 mali_csffw.bin，建议 mask" ;;
esac

if dmesg 2>/dev/null | grep -qiE 'Direct firmware load.*(csffw|mali)|Failed to load firmware|mali.*firmware.*(fail|error)'; then
	dmesg 2>/dev/null | grep -iE 'Direct firmware load|firmware' | tail -3 | sed 's/^/    /'
	bad "dmesg 里有固件直载/加载失败记录 —— 说明内核在用磁盘固件，这类问题要当真"
fi

# ── L3 设备节点 ─────────────────────────────────────────────────────────────
sec "L3 设备节点"
[[ -c /dev/mali0 ]] && ok "/dev/mali0 存在（kbase 用户态接口）" \
	|| warn "/dev/mali0 不存在（若已改用 panthor 内核驱动，这一项可忽略）"

if [[ -d /dev/dri ]]; then
	echo "  /dev/dri: $(ls /dev/dri | tr '\n' ' ')"
	[[ -d /dev/dri/by-path ]] && ls -l /dev/dri/by-path/ 2>/dev/null | sed 's/^/  /'
	if [[ -e /dev/dri/renderD128 || -e /dev/dri/card0 ]]; then
		ok "DRM 节点存在（card0=VOP 显示，rknpu 也会占一个；看 by-path 才知道哪个是 GPU）"
	else
		bad "/dev/dri 下没有可用节点"
	fi
else
	bad "/dev/dri 不存在，显示/渲染栈起不来"
fi

if id -nG 2>/dev/null | grep -qwE 'render|video'; then
	ok "当前用户在 render/video 组，普通用户可访问 GPU"
else
	warn "当前用户不在 render/video 组（root 测没事，桌面应用要加组）"
fi

# ── L4 GPU 调频 / 状态（对应仓库里的 gpu-governor-performance.service）──────
sec "L4 GPU 调频与运行状态"
if [[ -n "$GPU_DEVFREQ" ]]; then
	ok "devfreq 节点: ${GPU_DEVFREQ}"
	echo "  governor = $(cat "${GPU_DEVFREQ}/governor" 2>/dev/null)"
	echo "  cur_freq = $(cat "${GPU_DEVFREQ}/cur_freq" 2>/dev/null) Hz"
	echo "  可用频率 = $(cat "${GPU_DEVFREQ}/available_frequencies" 2>/dev/null)"
	[[ -r "${GPU_DEVFREQ}/load" ]] && echo "  当前负载 = $(cat "${GPU_DEVFREQ}/load" 2>/dev/null)"
	gov="$(cat "${GPU_DEVFREQ}/governor" 2>/dev/null)"
	[[ "$gov" == "performance" ]] && ok "governor 已是 performance" \
		|| warn "governor=$gov（期望 performance）。该 service 带 '|| true'，sysfs 路径不符时静默失效"
else
	bad "找不到 fb000000.gpu 的 devfreq 节点，GPU 电源/时钟框架可能没注册"
fi
if [[ -r /sys/kernel/debug/mali0/version ]]; then
	ok "debugfs mali0/version: $(tr '\n' ' ' < /sys/kernel/debug/mali0/version 2>/dev/null)"
elif [[ -d /sys/kernel/debug/mali0 ]]; then
	ok "debugfs /sys/kernel/debug/mali0/ 可读，条目: $(ls /sys/kernel/debug/mali0 | tr '\n' ' ')"
else
	warn "debugfs 无 mali0（未 mount debugfs 时正常：mount -t debugfs none /sys/kernel/debug）"
fi
t=$(cat /sys/class/thermal/thermal_zone1/temp 2>/dev/null)
[[ -n "$t" ]] && echo "  GPU 温度 = $((t/1000)) °C"

# ── L5 用户态驱动库 ─────────────────────────────────────────────────────────
sec "L5 用户态驱动库"
for p in mesa-utils mesa-utils-extra libgl1-mesa-dri libegl1 libgles2; do
	dpkg-query -W -f='  ${Package} ${Version}\n' "$p" 2>/dev/null
done

echo "  已配置的图形源（含 PPA）："
grep -rns 'panfork\|jjriek\|liujianfeng' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
	| sed 's/^/    /' || echo "    (无)"

if ls "$LIBA"/dri/panfrost_dri.so >/dev/null 2>&1; then
	ok "存在 panfrost_dri.so（Mesa Gallium 驱动在位，但能否用取决于内核：kbase 用不了它）"
else
	warn "没有 panfrost_dri.so"
fi

if ls "$LIBA"/libmali*.so* >/dev/null 2>&1; then
	echo "  libmali 相关库（链接目标 + 实体大小）："
	for _f in "$LIBA"/libmali*.so*; do
		[[ -e "$_f" || -L "$_f" ]] || continue
		_real="$(readlink -f "$_f" 2>/dev/null)"
		_sz="$(stat -c %s "$_real" 2>/dev/null || echo 0)"
		_tg="$(readlink "$_f" 2>/dev/null)"
		printf "    %-46s %12s B%s\n" "$(basename "$_f")" "$_sz" "${_tg:+  -> $_tg}"
	done
	_blob="$(find /usr/lib -maxdepth 3 -name 'libmali*.so*' -size +5M 2>/dev/null | head -1)"
	if [[ -n "$_blob" ]]; then
		ok "存在 libmali 实体 blob: $_blob"
		_blobver="$(grep -a -o -m1 -E 'g[0-9]{1,3}p[0-9]+' "$_blob" 2>/dev/null | head -1)"
		_kernver="$(dmesg 2>/dev/null | grep -i 'Kernel DDK version' | tail -1 | grep -oE 'g[0-9]{1,3}p[0-9]+' | head -1)"
		[[ -n "$_blobver" ]] && echo "    用户态 blob 版本标记: $_blobver"
		[[ -n "$_kernver" ]] && echo "    内核 kbase DDK 版本:  $_kernver"
		if [[ -n "$_blobver" && -n "$_kernver" && "$_blobver" != "$_kernver" ]]; then
			warn "两者不一致（用户态 $_blobver vs 内核 $_kernver）：kbase 的用户态通常要与内核 DDK 版本匹配，"\
"否则 EGL 初始化会失败。这是闭源 libmali 路线的【首要】风险点"
		fi
	else
		bad "只有 libmali-hook 没有 libmali 实体库 —— 装了一半，EGL/GLES 仍归 Mesa"
	fi
	[[ -d "$LIBA/mali" ]] && {
		echo "  $LIBA/mali/（libmali 的 EGL/GLES/GBM 包装库）:"
		ls "$LIBA/mali" 2>/dev/null | sed 's/^/    /'
	}
fi

echo "  glvnd EGL 厂商配置 /usr/share/glvnd/egl_vendor.d/:"
ls /usr/share/glvnd/egl_vendor.d/ 2>/dev/null | sed 's/^/    /'
# 关键：ld 缓存里第一个命中的库才会被加载 —— 这决定 GL 与 GLES/EGL 各走谁
if command -v ldconfig >/dev/null 2>&1; then
	echo "  ld.so 实际命中（GL=Mesa 而 EGL/GLES=libmali 的混合状态是闭源路线的常见现象）："
	for _l in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
		_p="$(ldconfig -p 2>/dev/null | awk -v L="$_l" '$1==L {print $NF; exit}')"
		printf "    %-16s -> %s\n" "$_l" "${_p:-未命中}"
	done
fi
grep -rns 'mali' /etc/ld.so.conf.d/ /etc/ld.so.preload 2>/dev/null | sed 's/^/  ld.so.conf: /'

# ── L6 渲染器实测 ───────────────────────────────────────────────────────────
sec "L6 渲染器实测（最关键的一步）"
RENDERER=""
if [[ -n "$DISPLAY" ]] && command -v glxinfo >/dev/null 2>&1; then
	RENDERER="$(timeout 20 glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer string/{print $2}')"
	[[ -z "$RENDERER" ]] && warn "有 DISPLAY 但 glxinfo 拿不到连接：多半是 X 授权问题"\
"（root 通过 ssh -X/MoTTY 跑时缺 XAUTHORITY，见 L7 的处理）"
elif [[ -z "$DISPLAY" ]]; then
	warn "当前无 DISPLAY（headless/串口），L6 只能靠 L7 的 off-screen 压测"
else
	warn "没有 glxinfo（apt install mesa-utils）"
fi

if [[ -n "$RENDERER" ]]; then
	echo "  OpenGL(桌面 GL) renderer = ${RENDERER}"
	case "$RENDERER" in
		*Mali*|*Panfrost*|*PanVK*|*Panthor*) ok "桌面 GL 走 Mali 硬件渲染" ;;
		*llvmpipe*|*softpipe*|*swrast*|*Software*)
			if [[ -d "$LIBA/mali" ]] || ldconfig -p 2>/dev/null | grep -q 'libmali'; then
				warn "桌面 GL 是软件渲染 —— 若你走闭源 libmali 方案，这是【预期】的："\
"libmali 只提供 GLES/EGL、没有桌面 GL，glxinfo 永远显示 llvmpipe。请以下面的 GLES 结果为准"
			else
				bad "走的是 CPU 软件渲染（llvmpipe），GPU 没被用上"
			fi ;;
		*) warn "渲染器无法识别: ${RENDERER}" ;;
	esac
fi

# GLES/EGL 探针：闭源 libmali 路线唯一有效的判据（es2_info 来自 mesa-utils-extra）
if command -v es2_info >/dev/null 2>&1; then
	echo "  es2_info（GLES/EGL 真实通路）:"
	timeout 20 es2_info 2>&1 | grep -iE 'GL_VERSION|GL_RENDERER|GL_VENDOR|EGL_VERSION|arm_release' | head -6 | sed 's/^/    /'
else
	warn "没有 es2_info（apt install mesa-utils-extra）—— 闭源路线必须用它判定，glxinfo 不作数"
fi
if command -v eglinfo >/dev/null 2>&1; then
	echo "  eglinfo："
	timeout 20 eglinfo 2>/dev/null | grep -iE 'Device|Vendor|renderer|EGL_VERSION' | head -10 | sed 's/^/    /'
fi
for log in /var/log/Xorg.0.log "$HOME/.local/share/xorg/Xorg.0.log"; do
	if [[ -r "$log" ]]; then
		echo "  --- $(basename "$log") 摘要 ---"
		grep -iE 'glamor|DRI3|Mali|llvmpipe|EE\)' "$log" | tail -12 | sed 's/^/    /'
		break
	fi
done

# ── L7 压测 ─────────────────────────────────────────────────────────────────
if [[ "$BENCH" == "1" ]]; then
	sec "L7 压测（GPU 负载 + 频率）"
	BIN=""
	for b in glmark2-es2 glmark2 glmark2-es2-wayland; do
		command -v "$b" >/dev/null 2>&1 && BIN="$b" && break
	done
	if [[ -z "$BIN" ]]; then
		warn "没装 glmark2（apt install glmark2 glmark2-es2），跳过压测"
	else
		# root 经 ssh -X/串口跑时 XAUTHORITY 不对，会报 Unsupported authorisation protocol
		if [[ -n "${DISPLAY}" && -z "${XAUTHORITY}" ]]; then
			for xa in /home/*/.Xauthority /run/user/*/gdm/Xauthority; do
				[[ -r "$xa" ]] && export XAUTHORITY="$xa" && break
			done
			command -v xhost >/dev/null 2>&1 && xhost +si:localuser:root >/dev/null 2>&1
		fi
		F0="$(cat "${GPU_DEVFREQ}/cur_freq" 2>/dev/null || echo 0)"
		echo "  压测前 GPU 频率: ${F0} Hz，开始跑 ${BIN} ..."
		OUT=""
		[[ -n "$DISPLAY" ]] && OUT="$(timeout 180 "$BIN" 2>&1 | tail -30)"
		if [[ -z "$OUT" || "$OUT" == *"Could not initialize canvas"* || "$OUT" == *"uthorisation"* ]]; then
			warn "X11 起不来（Unsupported authorisation protocol = root 缺 XAUTHORITY），改用离屏渲染"
			OUT="$(timeout 180 "$BIN" --off-screen 2>&1 | tail -30)"
		fi
		echo "$OUT" | sed 's/^/    /'
		echo "$OUT" | awk '/[Gg]lmark2 Score|Score:/{s=$NF} END{if(s)print "  得分: "s}'
		if echo "$OUT" | grep -q '0x3001'; then
			warn "eglInitialize 返回 0x3001(EGL_NOT_INITIALIZED)：通常是①离屏(无 X)与 libmali 的 x11-gbm 变体"\
"不兼容，或②X 授权失败。请在 X 桌面会话里用窗口模式重测（glmark2-es2），不要用 --off-screen"
		fi
		if echo "$OUT" | grep -qE 'arm_release_ver|rk_so_ver'; then
			echo "  说明：输出里的 arm_release_ver 表示本次实际加载的是 Rockchip libmali（闭源），不是 Mesa"
		fi
		if echo "$OUT" | grep -qiE 'llvmpipe|Software'; then
			bad "压测期间仍是软件渲染（renderer=llvmpipe）"
		elif [[ -z "$OUT" || "$OUT" == *"Could not initialize canvas"* \
		     || "$OUT" == *"ailed to initialize"* || "$OUT" == *"ERROR"* ]]; then
			bad "压测根本没跑起来，不能据此判断 GPU 正常"
		else
			ok "压测跑通，且未出现 llvmpipe"
		fi
		F1="$(cat "${GPU_DEVFREQ}/cur_freq" 2>/dev/null || echo 0)"
		echo "  压测期间采样 GPU 频率: ${F1} Hz"
		if [[ "$F1" -gt "$F0" ]]; then
			ok "GPU 频率被负载拉起，说明真的在干活"
		elif [[ "$F0" == "$(cat "${GPU_DEVFREQ}/max_freq" 2>/dev/null)" ]]; then
			warn "已在最高频（governor=performance 锁频），频率不会变化，看 load 与得分即可"
		else
			warn "频率没变化，重跑并同时观察 $GPU_DEVFREQ/load"
		fi
		echo "  参考：G610 跑 glmark2 得分约 1500~2300；几百 → 十有八九是软渲染"
	fi
	sec "视频编解码（属 VPU/MPP，不是 GPU，但一起验更省事）"
	for f in mpp_service rga3; do
		dmesg 2>/dev/null | grep -qi "$f.*probe\|$f.*init" && ok "$f 已初始化" || warn "$f 未见初始化日志"
	done
	mpv --version >/dev/null 2>&1 && echo "  mpv: $(mpv --version | head -1)"
fi

# ── 汇总 ────────────────────────────────────────────────────────────────────
sec "结论"
echo -e "  OK=${PASS}  WARN=${WARN}  FAIL=${FAIL}"
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
	echo "  GPU 全链路正常。"
elif [[ "$FAIL" -eq 0 ]]; then
	echo "  GPU 基本可用，但上面有 WARN 项建议核对。"
else
	echo "  有 FAIL 项：先修 L1/L2（内核与 DTS），再谈用户态。"
fi
exit "$FAIL"
