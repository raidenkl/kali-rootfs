#!/bin/bash
# ============================================================================
# libmali-verify.sh —— 在【板卡上】验证「闭源方案」：Rockchip libmali + kbase
#
# 与 panfork-verify.sh（开源 panfork mesa 路线）并列，二者选一条走。
#
# ⚠ 判定方式与开源路线完全不同：
#     libmali 只提供 GLES / EGL / OpenCL，【没有桌面 GL】。
#     所以 `glxinfo` 在这套方案下【永远】显示 llvmpipe，X11 的 glamor 也用不上，
#     这是预期行为，不是故障。唯一有效的判据是 GLES 探针（es2_info / glmark2-es2）。
#
# 用法：
#   sudo bash libmali-verify.sh                 # 只读：谁提供 GL/GLES、blob 与内核 DDK 是否同版本
#   sudo bash libmali-verify.sh --probe         # 在 X 会话里用 GLES 工具实测（自动处理 XAUTHORITY）
#   sudo bash libmali-verify.sh --env <命令…>   # 用显式 LD_LIBRARY_PATH 指向 mali 目录跑命令（A/B 对比）
#   sudo bash libmali-verify.sh --unwire        # 收敛：注释掉全局 ld.so.conf 的 mali 目录（含备份）
#   sudo bash libmali-verify.sh --deep          # 深度取证：一次性收齐证据写到 /root/mali-deep.log
#   sudo bash libmali-verify.sh --nodisp        # 无显示探针：OpenCL / Vulkan 枚举（最能判定"能否驱动 kbase"）
#   sudo bash libmali-verify.sh --purge         # 应急恢复：卸载 libmali + 摘掉全局注入，让 Xorg 用回 Mesa
#   sudo bash libmali-verify.sh --install-deb /path/libmali-*.deb   # 安装 Rockchip 官方 libmali（自动备份固件）
#   sudo bash libmali-verify.sh --route          # 只读：打印"谁服务谁"的路由表与强制切换办法
#   sudo bash libmali-verify.sh --which <程序>   # 只读：判断某个程序实际会用 panfork 还是 libmali
#   sudo bash libmali-verify.sh --help
# ============================================================================

MALI_DIR=/usr/lib/aarch64-linux-gnu/mali
LDCONF=/etc/ld.so.conf.d/00-aarch64-mali.conf
LIB=/usr/lib/aarch64-linux-gnu

DO="" ; ASSUME_YES=0 ; DEB="" ; ENVCMD=() ; WHICH_TARGET=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--probe|--unwire|--deep|--nodisp|--purge|--route) DO="${1#--}" ;;
		--install-deb) DO="install-deb"; shift; DEB="${1:-}" ;;
		--which) DO="which"; shift; WHICH_TARGET="${1:-}" ;;
		--keep-global) KEEP_GLOBAL=1 ;;
		--yes|-y) ASSUME_YES=1 ;;
		--env) DO="env"; shift; ENVCMD=("$@"); break ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		*) echo "未知参数: $1（--help 看用法）"; exit 2 ;;
	esac
	shift
done

say()  { echo -e "\e[1;36m== $* ==\e[0m"; }
ok()   { echo -e "  \e[32m[OK]\e[0m   $*"; }
warn() { echo -e "  \e[33m[WARN]\e[0m $*"; }
bad()  { echo -e "  \e[31m[FAIL]\e[0m $*"; }
die()  { echo -e "\e[31mERROR: $*\e[0m" >&2; exit 1; }

confirm() {
	[[ "$ASSUME_YES" == "1" ]] && return 0
	echo
	read -r -p "  $1 [y/N] " _c
	[[ "$_c" == "y" || "$_c" == "Y" ]]
}

# CSF 固件在 Debian 系里常被压缩存放（.xz / .zst），只查裸文件名会误判成"不存在"。
# 注意：内核固件加载器优先用未压缩的同名文件，所以装了带裸 .bin 的 deb 后生效的固件会变。
FW_CANDIDATES=(/lib/firmware/mali_csffw.bin /lib/firmware/mali_csffw.bin.xz /lib/firmware/mali_csffw.bin.zst
               /usr/lib/firmware/mali_csffw.bin /usr/lib/firmware/mali_csffw.bin.xz /usr/lib/firmware/mali_csffw.bin.zst)
firmware_find() {
	local f
	for f in "${FW_CANDIDATES[@]}"; do
		[[ -f "$f" ]] && { echo "$f"; return 0; }
	done
	return 1
}

# ── 固件判读（比"文件在不在"重要得多）──────────────────────────────────────
# 本内核把 CSF 固件【编译进内核】了（CONFIG_MALI_CSF_INCLUDE_FW=y，内核镜像里含注册名
# g25p0-00eac0.mali_csffw.bin），所以磁盘上那份根本不参与工作。真正的风险是有人塞了
# 错版（mali-g610-firmware 只会链 g15p0/g17p0/g18p0，匹配不上就链 g15p0），
# 以及那个 set-mali-firmware.service 每次开机都会 rm -f 这个路径再重建软链。
kernel_image() {
	local k
	for k in /boot/Image-* /boot/vmlinuz-* /boot/Image; do
		[[ -f "$k" ]] && { echo "$k"; return 0; }
	done
	return 1
}
kernel_embeds_fw() {
	local k
	k="$(kernel_image)" || return 1
	grep -aq 'mali_csffw' "$k" 2>/dev/null
}

# 输出：embedded | absent | real | wrong-symlink:<代号> | symlink:<代号>
firmware_verdict() {
	local f t gen
	f="$(firmware_find || true)"
	if [[ -z "$f" ]]; then
		if kernel_embeds_fw; then echo "embedded"; else echo "absent"; fi
		return 0
	fi
	if [[ -L "$f" ]]; then
		t="$(readlink "$f")"
		gen="$(echo "$t" | grep -oE 'g[0-9]+p[0-9]+' | head -1)"
		case "$t" in
			*mali_csffw_g[0-9]*p[0-9]*) echo "wrong-symlink:${gen:-?}" ;;
			*)                          echo "symlink:${gen:-?}" ;;
		esac
		return 0
	fi
	echo "real"
}

# 把上面的判定翻译成人能读的一行（+ 需要处置时给出命令）
firmware_report() {
	local v kdk gen f sw
	f="$(firmware_find || true)"
	v="$(firmware_verdict)"
	kdk="$(kernel_ver)"
	case "$v" in
		embedded)
			ok "CSF 固件：磁盘上没有，但内核【内嵌】了（$(kernel_image) 里能搜到 mali_csffw）→ 内核不会读磁盘那份"
			;;
		absent)
			warn "CSF 固件：磁盘上没有，也无法确认内核内嵌（找不到可读的 /boot/Image-*）"
			;;
		real)
			ok "CSF 固件：$f 是真文件（$(stat -c %s "$f") B）"
			echo "    若内核内嵌固件则这份不会被读；若没内嵌，它才是真正生效的那份"
			;;
		symlink:*|wrong-symlink:*)
			gen="${v#*:}"
			if [[ -n "$kdk" && "$gen" != "$kdk" ]]; then
				warn "CSF 固件：$f 是指向【$gen】的错版软链（内核 DDK ${kdk}）"
				echo "    来源：mali-g610-firmware 的 set-mali-firmware.service 只认 g15p0/g17p0/g18p0，匹配不上就链 g15p0"
				echo "    危害：本内核固件内嵌 → 惰性；但该 service 每次开机都会 rm -f 该路径再重建软链，会顶掉真固件"
				echo "    收敛：sudo systemctl disable --now set-mali-firmware.service"
				echo "          sudo systemctl mask set-mali-firmware.service && sudo rm -f $f"
			else
				ok "CSF 固件：$f 指向【$gen】，与内核 DDK 一致"
			fi
			;;
	esac
	sw="$(systemctl is-enabled set-mali-firmware.service 2>/dev/null || true)"
	if [[ "$sw" == "masked" ]]; then
		ok "set-mali-firmware.service 已 masked（不会再开机改固件路径）"
	elif [[ -n "$sw" ]]; then
		warn "set-mali-firmware.service = $sw —— 每次开机都会 rm -f 并重建 mali_csffw.bin，建议 mask"
	fi
}

blob_path()  { find /usr/lib -maxdepth 3 -name 'libmali*.so*' -size +5M 2>/dev/null | head -1; }
blob_ver()   { local b; b="$(blob_path)"; [[ -n "$b" ]] && grep -a -o -m1 -E 'g[0-9]{1,3}p[0-9]+' "$b" 2>/dev/null | head -1; }
kernel_ver() { dmesg 2>/dev/null | grep -i 'Kernel DDK version' | tail -1 | grep -oE 'g[0-9]{1,3}p[0-9]+' | head -1; }

# 比较两个代号的代际：echo -1 表示 a<b、0 相等、1 表示 a>b；解析不出则输出空（调用方按"无法判定"处理）。
# 纯参数展开实现（这里刻意不用 sed/awk：一是快，二是本机 Windows bash 里验证不了外部命令）。
# 先比 major（g 后面那个数）再比 minor —— 别把两段数字拼起来比（g9p0 会错判成 > g15p0）。
gen_cmp() {
	local a="$1" b="$2" x am aj bm bj
	x="${a#g}"; am="${x%%p*}"; aj="${x#*p}"; aj="${aj%%[!0-9]*}"
	x="${b#g}"; bm="${x%%p*}"; bj="${x#*p}"; bj="${bj%%[!0-9]*}"
	case "${am}${aj}${bm}${bj}" in *[!0-9]*|"") return 0 ;; esac
	[[ -n "$am" && -n "$aj" && -n "$bm" && -n "$bj" ]] || return 0
	# 10# 前缀：强制十进制，避免 08/09 被当八进制
	if   ((10#$am < 10#$bm)); then echo -1
	elif ((10#$am > 10#$bm)); then echo 1
	elif ((10#$aj < 10#$bj)); then echo -1
	elif ((10#$aj > 10#$bj)); then echo 1
	else echo 0; fi
}

# GLES 是否真的被交给 libmali（看 ld 缓存实际命中）——没装 libmali 时不能拿 llvmpipe 当"失败"
gles_goes_to_mali() {
	[[ -d "$MALI_DIR" ]] || return 1
	ldconfig -p 2>/dev/null | awk '$1=="libGLESv2.so.2"{print $NF; exit}' | grep -q "$MALI_DIR"
}

# X 是否真的连得上（不吃 GL/EGL，只用 xset）—— 这一步不做，GL 的失败就没法解释
xok() {
	[[ -n "$DISPLAY" ]] || return 1
	command -v xset >/dev/null 2>&1 || return 1
	timeout 8 xset q >/dev/null 2>&1
}

# 是否连的是 ssh/MobaXterm 端口转发过来的显示（形如 localhost:10.0 / host:10.0）。
# 这种显示 xset 能通，但 GL/EGL 【永远】不可用 —— 需要直接访问本地 DRM/DRI，转发通道不支持 ioctl
# （典型现象：XIO: fatal IO error 25 (Inappropriate ioctl for device)）。
is_forwarded_display() { [[ -n "$DISPLAY" && "$DISPLAY" =~ ^[^:]+: ]]; }

# 从运行中的 Xorg 进程参数里取 -auth 路径 —— :0 真正 cookie 位置最可靠的来源
xorg_auth_path() {
	command -v ps >/dev/null 2>&1 || return 0
	ps -eo args 2>/dev/null | grep -E '[X]org' | head -3 \
		| sed -n 's/.*-auth[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -1
}

# 依次尝试各种 X 授权来源，找到第一个真能连上的；失败返回 1
# 注意：① 转发显示对 GL 无效，必须先切回本地；② X 归谁所有因机器而异，必须逐个验证。
ensure_x() {
	local target="$DISPLAY"
	if is_forwarded_display; then
		warn "当前 DISPLAY=$DISPLAY 是转发来的 X（ssh/MobaXterm）：GL/EGL 在转发显示上必然失败，改试本地 :0"
		target=":0"
	fi
	local c
	local -a cands=()
	cands+=("$(xorg_auth_path)")
	cands+=("" "$HOME/.Xauthority" /root/.Xauthority /var/run/lightdm/root/:0)
	cands+=($(ls /home/*/.Xauthority /run/user/*/gdm/Xauthority /run/user/*/.mutter-Xwaylandauth.* 2>/dev/null))

	for c in "${cands[@]}"; do
		if [[ -z "$c" ]]; then
			if env -u XAUTHORITY DISPLAY="$target" timeout 8 xset q >/dev/null 2>&1; then
				unset XAUTHORITY; export DISPLAY="$target"
				echo "  X 可达：本地 $target，未设 XAUTHORITY（用默认 ~/.Xauthority）"
				return 0
			fi
		elif [[ -r "$c" ]] && DISPLAY="$target" XAUTHORITY="$c" timeout 8 xset q >/dev/null 2>&1; then
			export DISPLAY="$target" XAUTHORITY="$c"
			echo "  X 可达：本地 $target，XAUTHORITY=$c"
			return 0
		fi
	done

	export DISPLAY="$target"
	return 1
}

# 列出所有候选来源，诊断用
x_candidates() {
	local c
	local target="${DISPLAY:-:0}"
	is_forwarded_display && target=":0"
	echo "  当前 DISPLAY=${DISPLAY:-未设置}$( is_forwarded_display && echo ' ← 转发显示，GL/EGL 不可用' )"
	echo "  Xorg -auth 解析: $(xorg_auth_path || true)"
	echo "  候选 X 授权来源（对本地 $target 逐个试）："
	for c in "（不设置 XAUTHORITY）" "$(xorg_auth_path)" /root/.Xauthority "$HOME/.Xauthority" \
	         $(ls /home/*/.Xauthority 2>/dev/null) /var/run/lightdm/root/:0 $(ls /run/user/*/gdm/Xauthority 2>/dev/null); do
		if [[ "$c" == "（不设置 XAUTHORITY）" ]]; then
			if env -u XAUTHORITY timeout 8 xset q >/dev/null 2>&1; then
				echo "    $c  → 可用"
			else
				echo "    $c  → 失败"
			fi
		elif [[ -r "$c" ]]; then
			if XAUTHORITY="$c" timeout 8 xset q >/dev/null 2>&1; then
				echo "    $c  → 可用"
			else
				echo "    $c  → 存在但连不上"
			fi
		else
			echo "    $c  → 不存在"
		fi
	done
}

# ── 默认：只读状态 ─────────────────────────────────────────────────────────
status() {
	say "闭源 libmali 现状"
	echo "  内核: $(uname -r)"
	[[ -c /dev/mali0 ]] && ok "/dev/mali0 存在（kbase 就绪，闭源用户态依赖它）" \
		|| bad "/dev/mali0 不存在 —— kbase 未就绪，先修内核侧"

	local b bv kv
	b="$(blob_path)"
	if [[ -n "$b" ]]; then
		ok "实体 blob: $b（$(stat -c %s "$b") B）"
	else
		warn "未检测到 libmali 实体 blob（>5MB）—— 闭源方案未安装，当前走 Mesa/llvmpipe"
		echo "    要上闭源方案：装回 libmali 及其 EGL/GLES 包装库后再跑 --probe"
	fi
	bv="$(blob_ver)"; kv="$(kernel_ver)"
	echo "  用户态 blob 版本标记: ${bv:-未知}"
	echo "  内核 kbase DDK 版本:  ${kv:-未知}"
	if [[ -n "$bv" && -n "$kv" ]]; then
		# Rockchip 官方口径：**DDK 版本可以高于 mali-so，反过来不允许**。
		# 所以这个比较是有方向的 —— 不是"不同就有风险"，而是只有 blob 比内核新才危险。
		local _cmp; _cmp="$(gen_cmp "$bv" "$kv")"
		case "$_cmp" in
			0)  ok "用户态与内核 DDK 版本一致（$bv）" ;;
			-1) ok "blob $bv < 内核 DDK $kv —— 官方允许的组合（DDK 可高于 mali-so）"
				echo "    本板实测也支持：g13p0 / g24p0 两版用户态都能与 g25p0 内核正常通信" ;;
			1)  warn "blob $bv > 内核 DDK $kv —— 官方明说【不允许】（mali-so 不能比 DDK 高），这是最可能的失败原因"
				echo "    出路：换用 ≤ $kv 的用户态 blob，或把内核升到 ≥ $bv" ;;
			*)  warn "版本号不同（用户态 $bv vs 内核 $kv），代号格式无法比较高低"
				echo "    判据（Rockchip 口径）：DDK 可高于 mali-so；mali-so 不得高于 DDK" ;;
		esac
	fi
	[[ -d "$MALI_DIR" ]] && ok "包装库目录存在: $MALI_DIR" \
		|| warn "$MALI_DIR 不存在：需要 libmali 的 EGL/GLES/GBM 包装库"

	# 固件单独一节：它跟 blob 无关，判错会把人带偏（"文件在不在"不是重点）
	firmware_report

	if command -v ldconfig >/dev/null 2>&1; then
		echo "  ld.so 实际命中（加载顺序里第一个命中的生效）："
		for _l in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
			_p="$(ldconfig -p 2>/dev/null | awk -v L="$_l" '$1==L {print $NF; exit}')"
			printf "    %-16s -> %s\n" "$_l" "${_p:-未命中}"
		done
		if ldconfig -p 2>/dev/null | awk '$1=="libGLESv2.so.2"{print $NF; exit}' | grep -q "$MALI_DIR"; then
			ok "GLES 已指向 libmali（走 mali 目录的包装库）"
		else
			warn "GLES 当前命中的不是 libmali 目录 → 每次运行需显式 LD_LIBRARY_PATH=$MALI_DIR"
		fi
		if ldconfig -p 2>/dev/null | awk '$1=="libGL.so.1"{print $NF; exit}' | grep -q "$MALI_DIR"; then
			warn "桌面 GL 也被指向了 mali 目录 —— libmali 没有桌面 GL，这会让 GL 程序直接失败"
		fi
	fi
	echo "  glvnd EGL 厂商配置:"
	ls /usr/share/glvnd/egl_vendor.d/ 2>/dev/null | sed 's/^/    /'
	grep -rns 'mali' /etc/ld.so.conf.d/ /etc/ld.so.preload 2>/dev/null | sed 's/^/  ld.so.conf: /'
	# 全局注入一旦生效，Xorg 也会加载 libmali 的 EGL → glamor 着色器编译失败 → Xorg fatal
	if [[ -f "$LDCONF" ]] && grep -qE '^[[:space:]]*[^#[:space:]]' "$LDCONF" 2>/dev/null; then
		bad "全局注入处于【生效】状态 —— 已实证会让 Xorg 起不来（glamor GLSL 编译失败 → Fatal server error）"
		echo "    Xorg 日志特征：GL_EXT_blend_func_extended not supported / GLSL compile failure"
		echo "    建议：sudo bash $0 --unwire   然后 systemctl restart lightdm（改用按需 LD_LIBRARY_PATH）"
	fi

	say "通路归属（谁服务谁：panfork 与 libmali 能否共存就看这一节）"
	local _gl _egl _gles
	_gl="$(ldconfig -p 2>/dev/null | awk '$1=="libGL.so.1"{print $NF;exit}')"
	_egl="$(ldconfig -p 2>/dev/null | awk '$1=="libEGL.so.1"{print $NF;exit}')"
	_gles="$(ldconfig -p 2>/dev/null | awk '$1=="libGLESv2.so.2"{print $NF;exit}')"
	printf "  %-22s %s\n" "桌面 GL（GLX）" "${_gl:-未命中}"
	printf "  %-22s %s\n" "EGL/GLES（默认）" "${_egl:-未命中} / ${_gles:-未命中}"
	if [[ -d "$MALI_DIR" ]]; then
		printf "  %-22s %s\n" "EGL/GLES（按需）" "LD_LIBRARY_PATH=$MALI_DIR → libmali"
	fi
	[[ -f /etc/OpenCL/vendors/mali.icd ]] && printf "  %-22s %s\n" "OpenCL" "libmali（mali.icd）"
	[[ -f /usr/share/vulkan/icd.d/mali.json ]] && printf "  %-22s %s\n" "Vulkan" "libmali（mali.json）"
	if [[ -f "$LDCONF" ]] && grep -qE '^[[:space:]]*[^#[:space:]]' "$LDCONF" 2>/dev/null; then
		bad "全局注入【生效】= 两套栈真冲突：默认路径被 libmali 抢走 → Xorg 加载 mali 的 EGL → glamor 崩"
		echo "    → 必须 sudo bash $0 --unwire（这是共存唯一需要守住的约束）"
	else
		ok "全局注入已关闭 → 默认路径归 Mesa/panfork，libmali 只在显式 LD_LIBRARY_PATH 时接管 → 互不打扰"
	fi

	say "怎么判定它到底在工作"
	echo "  ⚠ 不要用 glxinfo（那是桌面 GL，闭源方案下恒为 llvmpipe）"
	echo "  → sudo bash $0 --probe           # 用 es2_info / glmark2-es2 在 X 会话里实测"
	echo "  → sudo bash $0 --env es2_info     # 强制 LD_LIBRARY_PATH 指向 mali 目录复测"
	echo
	echo "  预期能力边界：GLES 应用 / Chromium(--use-gl=egl) / mpv(rkmpp) / OpenCL 可硬件加速；"
	echo "               XFCE 桌面本身的合成仍是软件渲染（libmali 无桌面 GL，glamor 用不上）。"
}

# ── --probe：GLES 实测 ─────────────────────────────────────────────────────
probe() {
	say "GLES 实测（闭源方案唯一有效的判据）"
	[[ -n "$DISPLAY" || -n "$WAYLAND_DISPLAY" ]] \
		|| warn "当前没有 DISPLAY/WAYLAND_DISPLAY：libmali 的 x11-gbm 变体需要真实显示"

	# 第 0 步：先证 X 可达。libmali 的 x11 变体连不上 X 时【必然】报 0x3001，
	# 不先做这一步，后面的失败就无法解释，容易被误当成"驱动不工作"。
	if [[ -z "$DISPLAY" ]]; then
		bad "没有 DISPLAY —— 必须在桌面会话里跑，或显式带上 DISPLAY=:0"
	elif ! command -v xset >/dev/null 2>&1; then
		warn "没有 xset（apt install x11-xserver-utils），无法独立验证 X 可达性，结论不可信"
	elif ! ensure_x; then
		bad "X 不可达（当前环境 / 清空 XAUTHORITY / root 与各用户 cookie / lightdm 私有 auth 都试过）"
		x_candidates
		warn "此时 libmali 的 x11 变体【必然】eglInitialize 失败(0x3001)，这不算驱动证据。"
		echo "  两条路："
		echo "   ① 在 :0 所属的那个会话/用户下运行（上面哪个候选显示可用就用哪个）"
		echo "   ② 绕开 X 走 GBM（最干净，推荐）：sudo systemctl stop lightdm"
		echo "      sudo env -u DISPLAY LD_LIBRARY_PATH=$MALI_DIR glmark2-es2 --off-screen"
		echo "      sudo dmesg | tail -20 ; sudo systemctl start lightdm"
		echo
		read -r -p "  仍要继续跑 GLES 测试吗（结果不可信）？[y/N] " _a
		[[ "$_a" == "y" || "$_a" == "Y" ]] || return 0
	fi

	# 依赖按二进制判断，不按包名（glmark2-es2 由 glmark2-es2 包提供，glmark2 包里没有）
	for b in es2_info glmark2-es2; do
		if command -v "$b" >/dev/null 2>&1; then
			ok "$b 可用（$(dpkg -S "$(command -v "$b")" 2>/dev/null | cut -d: -f1)）"
		elif [[ "$b" == "es2_info" ]]; then
			warn "$b 缺失 → apt install mesa-utils-extra"
		else
			warn "$b 缺失 → apt install glmark2-es2"
		fi
	done

	GLES_OK=0
	local out rc
	if command -v es2_info >/dev/null 2>&1; then
		echo "  --- es2_info（默认库搜索顺序）---"
		out="$(timeout 20 es2_info 2>&1)"; rc=$?
		echo "$out" | grep -iE 'EGL_VERSION|EGL_VENDOR|GL_VERSION|GL_RENDERER|GL_VENDOR|arm_release|ERROR|Error' | sed 's/^/    /'
		if ! echo "$out" | grep -qi 'GL_RENDERER'; then
			echo "$out" | tail -5 | sed 's/^/    /'
		fi
		if echo "$out" | grep -qiE 'GL_RENDERER.*Mali'; then
			ok "GLES 走 Mali 硬件"
			GLES_OK=1
		elif echo "$out" | grep -q '0x3001'; then
			if gles_goes_to_mali; then
				bad "eglInitialize 0x3001 且 GLES 确实指向 libmali —— 见下面版本对照与成因区分"
			else
				warn "eglInitialize 0x3001，但当前 GLES 并不走 libmali（板上可能没装闭源驱动）"
			fi
		elif ! gles_goes_to_mali; then
			warn "GLES 走 Mesa（$(echo "$out" | awk -F': ' '/GL_RENDERER/{print $2}')）—— 板上未装 libmali，这是【软件渲染基线】，不是失败"
		else
			warn "未能确认 GLES 走 Mali（rc=$rc），看上面的原始输出"
		fi
	else
		warn "没有 es2_info：apt install mesa-utils-extra 后重跑"
	fi

	if [[ -d "$MALI_DIR" ]] && command -v es2_info >/dev/null 2>&1; then
		echo "  --- es2_info（显式 LD_LIBRARY_PATH=$MALI_DIR）---"
		out="$(LD_LIBRARY_PATH="$MALI_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" timeout 20 es2_info 2>&1)"
		echo "$out" | grep -iE 'EGL_VERSION|GL_VERSION|GL_RENDERER|arm_release|Error' | sed 's/^/    /'
	fi

	if command -v glmark2-es2 >/dev/null 2>&1 && [[ -n "$DISPLAY" ]]; then
		echo "  --- glmark2-es2（窗口模式，不要用 --off-screen）---"
		out="$(timeout 240 glmark2-es2 2>&1 | tail -18)"
		echo "$out" | sed 's/^/    /'
		echo "$out" | awk '/[Gg]lmark2 Score|Score:/{s=$NF} END{if(s)print "    得分: "s}'
		echo "$out" | grep -qiE 'arm_release_ver' && echo "    （arm_release_ver 行 = 确实加载了闭源 libmali）"
		if echo "$out" | grep -qiE 'llvmpipe'; then
			if gles_goes_to_mali; then
				bad "GLES 本应走 libmali，却得到 llvmpipe —— 闭源路线没生效"
			else
				warn "GLES 走 Mesa/llvmpipe，而板上没有 libmali —— 这是【软件渲染基线】，把这次的得分当作对照基准"
			fi
		fi
		if echo "$out" | grep -qiE 'eglInitialize.*failed'; then
			echo "    → 失败瞬间内核侧留了什么：sudo dmesg | tail -20"
		fi
	fi

	say "版本对照与结论"
	echo "  blob $(blob_ver) vs 内核 DDK $(kernel_ver)"
	case "$(gen_cmp "$(blob_ver)" "$(kernel_ver)")" in
		-1) echo "  → blob 低于内核：官方允许的组合（DDK 可高于 mali-so）" ;;
		0)  echo "  → 两者一致" ;;
		1)  echo "  → ⚠ blob 高于内核：官方明说不允许，若失败优先怀疑这里" ;;
		*)  : ;;
	esac
	if [[ "$GLES_OK" == "1" ]]; then
		ok "GO —— 闭源方案已生效：GLES/EGL 走 Mali（blob $(blob_ver)，内核 kbase $(kernel_ver)）"
		if [[ -f "$LDCONF" ]] && grep -qE '^[[:space:]]*[^#[:space:]]' "$LDCONF" 2>/dev/null; then
			bad "但全局注入仍在生效 → Xorg 也加载 mali 库：glamor 的 GLSL 会编译失败 → Xorg fatal → 桌面起不来"
			echo "    必须先：sudo bash $0 --unwire  （保留按需 LD_LIBRARY_PATH 用法）"
		fi
		echo "  能力边界：OpenGL ES 3.2 / OpenCL 3.0 / Vulkan；桌面 GL（glamor、glxinfo）libmali 结构性给不了"
		echo "  下一步按可行性排序："
		echo "    ① 无 X 的 DRM/GBM 直出（最稳）：apt install kmscube"
		echo "       sudo systemctl stop lightdm"
		echo "       sudo env -u DISPLAY LD_LIBRARY_PATH=$MALI_DIR kmscube ; sudo systemctl start lightdm"
		echo "    ② 计算通路（已验证可用）：clinfo / vulkaninfo"
		echo "    ③ 桌面 GL 加速：libmali 给不了 → 转 panfork 或 panthor 内核"
		echo "    ④ 或者：换 wayland-gbm 变体的 libmali + Wayland 会话（compositor 用 GLES，绕开 stock Xorg 的 DRI 缺陷）"
		return 0
	fi
	if [[ -z "$(blob_ver)" ]]; then
		warn "板上没有 libmali blob —— 闭源方案未安装，当前 GLES/EGL 走 Mesa（llvmpipe 属预期，不是失败）"
		echo "  要测闭源方案：先装回 libmali 及其 EGL/GLES 包装库（对应 $MALI_DIR），再跑 --probe"
	elif [[ "$(blob_ver)" == "$(kernel_ver)" ]]; then
		ok "用户态与内核 DDK 代际一致（$(blob_ver)）—— 若仍失败，跑 --deep 用 strace 定位"
	else
		warn "代际不同（用户态 $(blob_ver) vs 内核 $(kernel_ver)）—— 首要嫌疑，但不是唯一可能："
		echo "        另一种是 X11 集成：libmali 的 x11 变体通常要配 Rockchip 打过补丁的 Xorg（+libdrm-cursor）。"
		echo
		echo "  X 可达性上面已自动验证：X 不可达时 0x3001 是必然，不算驱动证据。"
		echo "  要进一步区分，就绕开 X 走 GBM："
		echo "    sudo systemctl stop lightdm"
		echo "    sudo env -u DISPLAY LD_LIBRARY_PATH=$MALI_DIR glmark2-es2 --off-screen"
		echo "    sudo dmesg | tail -20 ; sudo systemctl start lightdm"
		echo "  若 GBM 也失败 → sudo bash $0 --deep，用 strace 定罪："
		echo "    没打开 /dev/mali0 = X/DRM 集成层；打开了但 ioctl 被拒 = 用户态与内核代际不兼容。"
		echo
		echo "  出路：① 换与内核 $(kernel_ver) 同源的 libmali（LubanCat/Rockchip BSP 里那份，最稳）"
		echo "        ② 内核换回与 $(blob_ver) blob 配套的那版 BSP 内核"
		echo "        ③ 改走主线 panthor 内核 + Kali 自带 Mesa（需内核 ≥6.10，可拿回桌面 GL）"
	fi
}

# ── --env：显式库路径跑命令 ────────────────────────────────────────────────
run_env() {
	[[ ${#ENVCMD[@]} -gt 0 ]] || die "用法：--env <命令…>"
	[[ -d "$MALI_DIR" ]] || die "$MALI_DIR 不存在"
	if [[ -n "$DISPLAY" ]]; then
		ensure_x || warn "X 不可达：被测程序若需要显示，这次结果不作数（看 --probe 的候选列表）"
	fi
	echo "  LD_LIBRARY_PATH=$MALI_DIR 执行: ${ENVCMD[*]}"
	echo
	LD_LIBRARY_PATH="$MALI_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${ENVCMD[@]}"
}

# ── --unwire：收敛全局 ld.so.conf 注入 ─────────────────────────────────────
unwire() {
	say "收敛 libmali 的全局库路径注入"
	[[ -f "$LDCONF" ]] || { echo "  $LDCONF 不存在，无需处理"; return 0; }
	echo "  当前内容："; sed 's/^/    /' "$LDCONF"
	warn "该文件把 $MALI_DIR 插到库搜索最前面，会让 EGL/GLES/GBM 全局被 libmali 接管，"
	warn "与 Mesa 混装时容易出现'某些程序能用、某些直接崩'的诡异状态。"
	echo "  收敛后：改回按需 LD_LIBRARY_PATH=$MALI_DIR（上游推荐用法），Mesa 恢复默认。"
	read -r -p "  继续？[y/N] " a; [[ "$a" == "y" || "$a" == "Y" ]] || { echo "  已取消"; return 0; }
	cp -a "$LDCONF" "${LDCONF}.bak.$(date +%Y%m%d-%H%M%S)"
	sed -i 's|^[[:space:]]*[^#].*|# &   # 由 libmali-verify.sh --unwire 注释|' "$LDCONF"
	ldconfig
	ok "已注释并 ldconfig（备份见 ${LDCONF}.bak.*）"
	echo "  现在 GLES 程序需显式指定：LD_LIBRARY_PATH=$MALI_DIR <程序>"
	ldconfig -p 2>/dev/null | awk '$1=="libGLESv2.so.2"{print "  libGLESv2.so.2 -> "$NF; exit}'
}

# ── --deep：一次收齐取证材料 ───────────────────────────────────────────────
deep() {
	local LOG=/root/mali-deep.log
	say "深度取证 → $LOG"
	: > "$LOG"

	{
		echo "### 0 基本信息"
		date; uname -a
		echo "DISPLAY=${DISPLAY:-（未设置）} XAUTHORITY=${XAUTHORITY:-（未设置）}"
		echo; echo "### 1 X 可达性（逐候选验证；这一步不过，GL 的失败都不算驱动证据）"
	} >>"$LOG" 2>&1
	if command -v xset >/dev/null 2>&1; then
		x_candidates >>"$LOG" 2>&1
		if ensure_x >>"$LOG" 2>&1; then
			echo "→ 结论：X 可达，后面的 GL/EGL 失败可作为驱动侧证据" >>"$LOG"
		else
			echo "→ 结论：X 不可达！后面 GL/EGL 的失败【不能】当驱动证据，先解决 X 会话/授权" >>"$LOG"
		fi
	else
		echo "→ 没有 xset（apt install x11-xserver-utils），无法验证 X 可达性" >>"$LOG"
	fi

	{
		echo; echo "### 2 内核侧：GPU / DDK / 固件"
		dmesg | grep -iE 'mali|kbase|csf|firmware' | tail -25
		echo; echo "固件判定: $(firmware_verdict)（embedded=内核内嵌、磁盘文件惰性 / wrong-symlink=错版残留）"
		echo "内核镜像: $(kernel_image 2>/dev/null || echo '未找到')  内嵌固件: $(kernel_embeds_fw && echo yes || echo no)"
		for c in "${FW_CANDIDATES[@]}"; do [[ -f "$c" ]] && ls -l "$c"; done
		for c in "${FW_CANDIDATES[@]}"; do [[ -L "$c" ]] && echo "软链: $c -> $(readlink "$c")"; done
		md5sum $(firmware_find) 2>/dev/null
		echo "set-mali-firmware.service: $(systemctl is-enabled set-mali-firmware.service 2>/dev/null || echo '不存在/未启用')"
		dmesg | grep -iE 'Direct firmware load|csffw|mali.*firmware' | tail -10
		echo; echo "### 3 libmali 是谁装的（包来源）"
		dpkg -l 2>/dev/null | grep -iE 'mali' | grep -viE 'gpg|libmnl|try-tiny'
		for f in /usr/lib/aarch64-linux-gnu/libmali.so.1.9.0 \
		         /usr/lib/aarch64-linux-gnu/libmali-hook.so.1.9.0 \
		         /usr/lib/aarch64-linux-gnu/mali/libEGL.so.1; do
			printf '%s\n  -> %s\n' "$f" "$(dpkg -S "$f" 2>&1 | head -1)"
		done
		dpkg -l 2>/dev/null | grep -i mali
		echo "--- 仓库里还有哪些 libmali 变体 ---"
		apt list -a 'libmali*' 2>/dev/null | head -20
		echo; echo "### 4 库解析与 ld.so.conf"
		for l in libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libGL.so.1; do
			printf '%s -> %s\n' "$l" "$(ldconfig -p 2>/dev/null | awk -v L="$l" '$1==L{print $NF;exit}')"
		done
		sed 's/^/  /' /etc/ld.so.conf.d/00-aarch64-mali.conf 2>/dev/null
		ls /usr/share/glvnd/egl_vendor.d/ 2>/dev/null
	} >>"$LOG" 2>&1

	if command -v es2_info >/dev/null 2>&1; then
		echo >>"$LOG"; echo "### 5 es2_info（默认搜索顺序）" >>"$LOG"
		es2_info >>"$LOG" 2>&1 || true
	fi

	echo >>"$LOG"; echo "### 6 strace：定位失败发生在哪一步（最能定罪的一段）" >>"$LOG"
	if command -v strace >/dev/null 2>&1; then
		LD_LIBRARY_PATH="$MALI_DIR" strace -f -e trace=openat,ioctl -o /tmp/mali.strace \
			$(command -v es2_info >/dev/null 2>&1 && echo es2_info || echo glmark2-es2) >>"$LOG" 2>&1 || true
		{
			echo "----- 与 mali0 / dri / drm 相关的打开动作 -----"
			grep -nE 'mali0|/dev/dri|drm' /tmp/mali.strace 2>/dev/null | head -40
			echo "----- 失败的 ioctl（= -1）-----"
			grep -nE 'ioctl\(.*= -1' /tmp/mali.strace 2>/dev/null | head -30
			echo "----- 原始 strace 尾部 -----"
			tail -20 /tmp/mali.strace 2>/dev/null
		} >>"$LOG"
	else
		echo "strace 未安装 → sudo apt install strace 后重跑本命令" >>"$LOG"
	fi

	echo >>"$LOG"; echo "### 7 失败后的 dmesg 尾部" >>"$LOG"
	dmesg | tail -25 >>"$LOG" 2>&1

	ok "已写入 $LOG"
	echo "  把这个文件的内容贴回来即可（第 6 段最关键）"
	echo "  判读："
	echo "   • strace 里根本没打开 /dev/mali0 → 失败在 X/DRM 集成层，不是 DDK"
	echo "   • 打开了 /dev/mali0 但 ioctl 报 EINVAL/ENOTTY → kbase 接口代际不兼容（用户态与内核不配套）"
}

# ── --install-deb：安装 Rockchip 官方 libmali（关键：备份固件）─────────────
install_deb() {
	[[ -n "$DEB" && -f "$DEB" ]] || die "用法：--install-deb /path/to/libmali-*.deb"
	local fw=/lib/firmware/mali_csffw.bin
	local bak=/root/mali_csffw.bin.orig
	say "安装 libmali deb: $(basename "$DEB")"

	if command -v dpkg-deb >/dev/null 2>&1; then
		echo "  包信息："; dpkg-deb -f "$DEB" Package Version Architecture Depends 2>/dev/null | sed 's/^/    /'
	fi

	# ⚠ 该包内含 /lib/firmware/mali_csffw.bin，安装会【覆盖/顶替】板上现有 CSF 固件
	#   （若现有固件是 .xz/.zst 压缩形态，未压缩的同名文件优先级更高，生效的固件同样会变）。
	#   内核若与这份固件不对版，GPU 可能起不来 —— 先备份，出问题可一键还原。
	local fw; fw="$(firmware_find || true)"
	if [[ -n "$fw" ]]; then
		[[ -f "$bak" ]] || cp -a "$fw" "$bak"
		ok "固件已备份 → $bak（源: $fw）"
		echo "    现有固件: $(basename "$fw")  md5=$(md5sum "$fw" | awk '{print $1}')  size=$(stat -c %s "$fw")"
		[[ "$fw" != "/lib/firmware/mali_csffw.bin" ]] \
			&& warn "现有固件是压缩形态，内核会优先加载未压缩的同名文件 → 装完 deb 后【生效的固件会变】"
	else
		# 本板实测：内核把 CSF 固件编进去了（CONFIG_MALI_CSF_INCLUDE_FW=y，不是通用的
		# CONFIG_EXTRA_FIRMWARE —— 后者在本内核里是空的）。判据是内核镜像里能搜到 mali_csffw。
		if kernel_embeds_fw; then
			ok "未找到 mali_csffw.bin —— 但内核【内嵌】了 CSF 固件（$(kernel_image) 里含 mali_csffw）"
			echo "    所以装的裸 .bin 不会被内核读取，这一步不影响运行；只是路径上会多一个文件"
		else
			warn "未找到 mali_csffw.bin（含 .xz/.zst 变体），且无法确认内核内嵌固件"
			echo "    若内核确实依赖磁盘固件，装进去的这份就会【真正生效】—— 版本不对可能让 GPU 起不来"
			echo "    核查：dmesg | grep -iE 'Direct firmware load|csffw' | tail -20（无 direct-loading 行 = 内嵌）"
		fi
	fi
	if command -v dpkg-deb >/dev/null 2>&1; then
		local td; td="$(mktemp -d)"
		if dpkg-deb -x "$DEB" "$td" 2>/dev/null && [[ -f "$td/lib/firmware/mali_csffw.bin" ]]; then
			echo "    deb 内固件: md5=$(md5sum "$td/lib/firmware/mali_csffw.bin" | awk '{print $1}')  size=$(stat -c %s "$td/lib/firmware/mali_csffw.bin")"
			echo "    （两者 md5 不同 = 安装后会换固件，需留意 dmesg 是否报固件错误）"
		fi
		rm -rf "$td"
	fi

	dpkg -l 2>/dev/null | grep -iE 'mesa|libgl|libegl|libgbm' > /root/mesa-before.txt
	ok "Mesa 基线已存 /root/mesa-before.txt（回滚对照）"

	confirm "现在安装？" || { echo "  已取消"; return 0; }

	# 用 apt 而不是 dpkg -i，便于自动满足 Depends（libx11-6 / libx11-xcb1 / libxcb-dri2-0 / libdrm2）
	apt install -y "$DEB" || apt install -y --fix-broken || die "安装失败，见上方输出"
	ldconfig
	ok "安装完成（该包的 trigger 会自动跑 ldconfig）"

	# ⚠ 关键：该包会装 /etc/ld.so.conf.d/00-aarch64-mali.conf，把 mali 库插到全局搜索最前。
	#   已实证后果：Xorg 自己也加载 libmali 的 EGL/GBM → glamor 的 glyph 着色器需要
	#   GL_EXT_blend_func_extended（dual-source blending），libmali 的 GLES 不支持 →
	#   "GLSL compile failure" → Xorg "Fatal server error" → lightdm 崩溃重启死循环
	#   （现象：HDMI 持续刷 dwhdmi use tmds mode、桌面起不来）。
	#   因此默认摘掉全局注入，改用按需 LD_LIBRARY_PATH（上游也是这么推荐的）。
	if [[ -f "$LDCONF" && "${KEEP_GLOBAL:-0}" != "1" ]]; then
		cp -a "$LDCONF" "${LDCONF}.bak.$(date +%Y%m%d-%H%M%S)"
		sed -i 's|^[[:space:]]*[^#].*|# &   # disabled by libmali-verify.sh: 会让 Xorg/glamor 崩|' "$LDCONF"
		ldconfig
		warn "已自动摘掉全局注入 $LDCONF（否则 Xorg 桌面起不来）"
		echo "    GLES/Vulkan 应用按需启用：LD_LIBRARY_PATH=$MALI_DIR <程序>"
		echo "    要恢复全局注入：还原 ${LDCONF}.bak.* 后 ldconfig（不推荐）；或装包时加 --keep-global"
	fi
	if [[ -f /etc/profile.d/mali-priority.sh ]]; then
		echo "  提示：/etc/profile.d/mali-priority.sh 设了 MALI_SCHED_RT_THREAD_PRIORITY=95（仅 login shell 生效）"
	fi

	echo "  固件现状: $(firmware_find 2>/dev/null || echo '未找到')  md5=$(md5sum $(firmware_find) 2>/dev/null | awk '{print $1}')"
	if [[ -n "$fw" && "$(firmware_find)" != "$fw" ]]; then
		warn "生效固件路径已变：$fw → $(firmware_find)（未压缩文件顶替了压缩文件）"
	fi
	# 装完再看一遍固件判定：既解释"为什么这个文件其实不被读"，也顺手抓错版/漏 mask
	firmware_report
	echo
	status
	echo
	warn "下一步：sudo bash $0 --probe    （X 可达时才是有效测试）"
	echo "  若 GPU 起不来：cp -a $bak $fw  然后 reboot"
}

# ── --nodisp：不依赖显示的探针（最能回答"用户态能否驱动 kbase"）────────────
# 原理：OpenCL / Vulkan 的枚举都不需要 X、不需要 GBM、不需要 canvas，
#       libmali 的 mali.icd / mali.json 会直接对着 /dev/mali0 说话。
#       所以这一条能把"X/EGL 显示集成问题"和"用户态与内核代际不兼容"彻底分开。
nodisp() {
	say "无显示探针：OpenCL / Vulkan（不经 X、不经 GBM）"

	echo "  -- ICD 注册情况 --"
	[[ -f /etc/OpenCL/vendors/mali.icd ]] \
		&& echo "  OpenCL ICD: $(cat /etc/OpenCL/vendors/mali.icd)" \
		|| warn "缺 /etc/OpenCL/vendors/mali.icd —— OpenCL 不会走 Mali"
	[[ -f /usr/share/vulkan/icd.d/mali.json ]] \
		&& echo "  Vulkan ICD: $(tr -d '\n' < /usr/share/vulkan/icd.d/mali.json)" \
		|| warn "缺 /usr/share/vulkan/icd.d/mali.json —— Vulkan 不会走 Mali"

	# ICD 文件里写的是【裸库名】，能否解析决定该通路可不可用。
	# 这里把状态一次列清 —— "ldconfig 缓存里没有"不等于"用不了"（dlopen 还会看
	# LD_LIBRARY_PATH 和调用方的 RPATH/RUNPATH），所以两者要分开说。
	local lib lh lstat
	for lib in libMaliOpenCL.so.1 libMaliVulkan.so.1; do
		lh="$(ldconfig -p 2>/dev/null | awk -v L="$lib" '$1==L{print $NF; exit}')"
		if [[ -n "$lh" ]]; then
			lstat="ldconfig 缓存里【有】($lh) → 免设置可用"
		elif [[ -e "$MALI_DIR/$lib" ]]; then
			lstat="ldconfig 缓存里【无】，但 $MALI_DIR 下有文件 → 只有按需(LD_LIBRARY_PATH)才通"
		else
			lstat="ldconfig 缓存里无、$MALI_DIR 下也没有 → 该通路不可用"
		fi
		echo "  ICD 库 $lib：$lstat"
	done

	# 多份 libmali 检测：两份 blob 会让 OpenCL 出现多个平台、程序可能选到不同版本。
	# （本仓库固化时不需要担心：build-rootfs.sh 只装 packages/gpu/*.deb，且 README 明确
	#   警告不要同时放多个提供 libmali 的 deb；这里主要抓"手工装过好几份"的板子。）
	local blobs nb
	blobs="$(find /usr/lib/aarch64-linux-gnu -maxdepth 2 -name 'libmali*.so*' -size +5M 2>/dev/null)"
	if [[ -n "$blobs" ]]; then
		nb="$(echo "$blobs" | wc -l)"
		echo "  实体 blob（>5MB）共 $nb 份:"
		echo "$blobs" | sed 's/^/    /'
		if [[ "$nb" -gt 1 ]]; then
			warn "装了 $nb 份 libmali —— 程序可能选到不同版本的 blob，建议只保留一份"
			echo "      核查：dpkg -l | grep -i mali   /   ls -l /etc/OpenCL/vendors/"
		fi
	fi

	local out
	echo
	echo "  -- OpenCL --"
	if command -v clinfo >/dev/null 2>&1; then
		out="$(timeout 90 clinfo 2>&1)"
		# 判据用「真的有一行 Device Name」而不是裸 grep 'Mali'：ICD 报错信息里
		# 也会带 libMaliOpenCL.so.1 这个名字，裸 grep 会把报错误判成枚举成功。
		if ! echo "$out" | grep -qi 'Device Name'; then
			# --unwire 之后 mali 目录不在默认搜索路径里，ICD 里的 libMaliOpenCL.so.1 可能解析不到
			local out2; out2="$(timeout 90 env LD_LIBRARY_PATH="$MALI_DIR" clinfo 2>&1)"
			if echo "$out2" | grep -qi 'Device Name'; then
				out="$out2"
				echo "    （默认路径下 ICD 解析不到 libMaliOpenCL.so.1；显式 LD_LIBRARY_PATH 后可用）"
				echo "     → 要让 OpenCL/Vulkan 免设置可用：sudo bash $0 --route"
			fi
		fi
		echo "$out" | grep -iE 'Number of platforms|Platform Name|Platform Vendor|Device Name|Device Version|cannot open shared object|no platforms|Error' | head -14 | sed 's/^/    /'
		if echo "$out" | grep -qiE 'cannot open shared object|Error loading|failed to load'; then
			warn "OpenCL 加载器报错：ICD 里的库名解析不到（见上方行）—— 它不是「用户态与内核不兼容」"
			echo "    按需用法：LD_LIBRARY_PATH=$MALI_DIR clinfo ；免设置办法见 bash $0 --route"
		elif echo "$out" | grep -qi 'Device Name'; then
			ok "OpenCL 枚举到 Mali 设备 → 用户态 blob 能与内核 kbase 正常通信"
			# 抹出所有出现过的 blob 构建代号（gXXpYY）：多于一个说明板上装了多份 libmali。
			# 用 wc -w 数字数（别用 `case *" "*`：单个代号也会带一个尾随空格，会误报）。
			local nver ncnt
			nver="$(echo "$out" | grep -oE 'v1\.g[0-9]+p[0-9]+-' | sed 's/^v1\.//; s/-$//' | sort -u | tr '\n' ' ')"
			if [[ -n "$nver" ]]; then
				echo "    枚举到的 blob 代号: ${nver}"
				ncnt="$(echo "$nver" | wc -w)"
				[[ "$ncnt" -gt 1 ]] && warn "同一个系统上出现了 $ncnt 个不同代号的 libmali（$nver）→ 板上装了两份，建议只留一份"
			fi
		else
			warn "OpenCL 未见 Mali 设备（可能是代际不兼容，或 ICD 未生效）"
		fi
	else
		echo "    未装 clinfo → apt install -y clinfo 后重跑"
	fi

	echo
	echo "  -- Vulkan --"
	# ICD JSON 里写的是【裸库名】(library_path)，所以要先看这个名字能不能解析到实体库。
	# 三种结局完全不同：能解析 / 文件在但不在搜索路径 / 这份 blob 根本没提供该库。
	local vlib vhit
	vlib="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /usr/share/vulkan/icd.d/mali.json 2>/dev/null | head -1)"
	if [[ -n "$vlib" ]]; then
		vhit="$(ldconfig -p 2>/dev/null | awk -v L="$vlib" '$1==L{print $NF; exit}')"
		if [[ -n "$vhit" ]]; then
			echo "    ICD library_path = $vlib → 可解析: $vhit"
		elif [[ -e "$MALI_DIR/$vlib" ]]; then
			echo "    ICD library_path = $vlib → 文件在 $MALI_DIR 下，但不在默认搜索路径"
			# 标准目录里如果有一条"悬空软链"，最容易把人带偏（loader 报的 No such file 就是它）
			if [[ -L "$LIB/$vlib" && ! -e "$LIB/$vlib" ]]; then
				echo "      ⚠ $LIB/$vlib 是一条【悬空软链】（目标不存在）→ 删掉它，或重建指向 $MALI_DIR/$vlib"
			elif [[ -L "$LIB/$vlib" ]]; then
				echo "      提示：$LIB/$vlib 已存在软链，但 ldconfig 缓存里没有 → 补跑一次 ldconfig"
			fi
			echo "      → loader 会报 'cannot open shared object file'，按需用法："
			echo "        LD_LIBRARY_PATH=$MALI_DIR vkcube     （或 bash $0 --route 看免设置的固定办法）"
		else
			echo "    ICD library_path = $vlib → 既不在搜索路径、也不在 $MALI_DIR 下"
			echo "      → 这份 blob 没有提供该库：Vulkan 在这个 blob 上不可用（换一份 blob 才有）"
			echo "      核查：ls $MALI_DIR | grep -i vulkan"
		fi
	fi
	if command -v vulkaninfo >/dev/null 2>&1; then
		out="$(timeout 90 vulkaninfo --summary 2>&1)"
		echo "$out" | grep -iE 'deviceName|driverName|apiVersion|ERROR' | head -12 | sed 's/^/    /'
		# ★ 判据必须严谨：loader 的报错里会带上库名 libMaliVulkan.so.1，
		#   用 grep -i 'Mali' 去判会把这些报错误当成"枚举到 Mali"。
		if echo "$out" | grep -qiE 'Found no drivers|cannot open shared object|ERROR_INCOMPATIBLE_DRIVER|vkCreateInstance failed'; then
			warn "Vulkan 未枚举到设备（原因见上方 ERROR 行，多半就是 ICD 那行解析不了）"
			echo "      ⚠ 别把 'Failed loading library ... libMaliVulkan.so.1' 这类行当成成功提示"
		elif echo "$out" | grep -qiE 'deviceName|GPU id'; then
			ok "Vulkan 枚举到设备（见上方 deviceName）"
		elif echo "$out" | grep -qiE 'XDG_RUNTIME_DIR|XCB failed|AppCreateXcbSurface'; then
			warn "vulkaninfo 缺显示/XDG_RUNTIME_DIR，建不了 surface —— 这【不算】驱动失败"
			echo "    结论以 OpenCL 与上面的 ICD 解析为准"
		else
			warn "Vulkan 无法判定（既没 deviceName，也没有明确的 loader 报错）"
		fi
	else
		echo "    未装 vulkaninfo → apt install -y vulkan-tools 后重跑"
	fi

	echo
	echo "  判读：OpenCL 枚举到 Mali 就已证明「用户态 blob ↔ 内核 kbase」通路正常"
	echo "        （它不需要显示器/桌面/X，是固化进构建流程或做出厂验证最合适的一条）；"
	echo "        Vulkan 是叠加项：先看上面 ICD 的 library_path 能否解析，再看 loader 有没有报 no drivers；"
	echo "        用 glxinfo/glmark2 判 libmali 是错的 —— 那是桌面 GL，libmali 结构上给不了。"
}

# ── --route：谁服务谁（路由表 + 强制切换办法）────────────────────────────
# 两套栈都骑在同一个内核驱动 kbase 上，只靠【库搜索路径】二选一：
#   默认路径（系统目录） = panfork/Mesa  → X11 桌面、GLX
#   前置 mali 目录        = libmali blob → OpenCL/Vulkan/无 X 的 GBM 直出
route() {
	say "通路路由：哪个程序走哪套驱动"
	echo "  两套用户态共用内核 kbase（/dev/mali0），靠库搜索路径二选一。"
	echo
	echo "  [默认] 不设任何环境变量 → panfork（Mesa）"
	local l hit
	# 后两个是 ICD 用到的裸库名：它们能不能解析，直接决定 OpenCL/Vulkan 可不可用
	for l in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libMaliOpenCL.so.1 libMaliVulkan.so.1; do
		hit="$(ldconfig -p 2>/dev/null | awk -v L="$l" '$1==L{print $NF;exit}')"
		printf "    %-20s -> %s\n" "$l" "${hit:-（不在 ldconfig 缓存里）}"
	done
	echo "    适合：X11/桌面程序、glxinfo、GLX 应用（libmali 的那条 X11 路在 stock Xorg 上不通）"
	echo
	echo "  [按需] 前置 mali 目录 → libmali（闭源 ARM blob）"
	echo "    LD_LIBRARY_PATH=$MALI_DIR <程序>"
	echo "    适合：OpenCL / Vulkan 计算、无 X 的 GBM/DRM 直出（kmscube、mpv --vo=gpu 等）"
	echo "    ⚠ 同一个进程里别混用两套 EGL/GLES；LD_LIBRARY_PATH 会传给子进程，注意别随手 export"
	echo
	local g; g="$(grep -h '^[^#]' "$LDCONF" 2>/dev/null)"
	if [[ -n "$g" ]]; then
		bad "全局 ld.so.conf 注入【当前生效】→ Xorg 也会加载 libmali 的 EGL/GBM，桌面会崩"
		echo "    先跑：sudo bash $0 --unwire"
	else
		ok "全局注入未生效（正确状态）：默认归 panfork，libmali 只按需启用"
	fi
	echo
	echo "  [让计算通路免设置] OpenCL/Vulkan 的 ICD 需要解析到 libMali*.so.1，"
	echo "  而 mali 目录不在默认搜索路径（正是摘掉全局注入的结果）。三条办法："
	echo "    ① 临时显式带路径：  LD_LIBRARY_PATH=$MALI_DIR clinfo"
	echo "    ② 只给 ICD 两库做软链（推荐、可逆、不影响 Xorg —— 名字唯一，Xorg 不会加载它们）："
	echo "         ln -sf $MALI_DIR/libMaliOpenCL.so.1 $LIB/libMaliOpenCL.so.1"
	echo "         ln -sf $MALI_DIR/libMaliVulkan.so.1 $LIB/libMaliVulkan.so.1"
	echo "         ldconfig && clinfo | grep -i 'Device Name'"
	echo "         撤销：rm -f $LIB/libMaliOpenCL.so.1 $LIB/libMaliVulkan.so.1 && ldconfig"
	echo "    ③ 或用 PPA 的包装器： apt install malirun ; malirun clinfo"
	echo
	echo "  [查某个程序实际会用哪套]  sudo bash $0 --which <程序名或路径>"
}

# ── --which：判断某程序将走哪套（只读）──────────────────────────────────
which_cmd() {
	local t="$WHICH_TARGET"
	[[ -z "$t" ]] && die "用法：--which <程序名或 .so 路径>"
	local p
	p="$(command -v "$t" 2>/dev/null || true)"
	[[ -z "$p" ]] && p="$t"
	[[ -e "$p" ]] || die "找不到 $t"
	say "这个程序会用哪套：$p"

	local deps=""
	if command -v readelf >/dev/null 2>&1; then
		deps="$(readelf -d "$p" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
	elif command -v objdump >/dev/null 2>&1; then
		deps="$(objdump -p "$p" 2>/dev/null | sed -n 's/.*NEEDED[[:space:]]*//p')"
	fi
	local rel; rel="$(echo "$deps" | grep -E '^lib(GL|EGL|GLESv|gbm|GLX|OpenCL|vulkan)' | tr '\n' ' ')"
	if [[ -z "$rel" ]]; then
		warn "未直接链接 GL/EGL/GLES/GBM（可能经 dlopen 加载，或本身不碰 GPU）"
	else
		echo "  直接依赖: $rel"
	fi
	local hit; hit="$(ldd "$p" 2>/dev/null | grep -E 'libGL\.so|libEGL|libGLESv|libgbm')"
	[[ -n "$hit" ]] && echo "$hit" | sed 's/^/    /'
	if echo "$hit" | grep -q "$MALI_DIR"; then
		ok "→ 会走 libmali（闭源 blob）"
	else
		ok "→ 会走 panfork / Mesa（系统路径）"
	fi
	echo
	echo "  强制切换："
	echo "    走 libmali： LD_LIBRARY_PATH=$MALI_DIR $t"
	echo "    走 panfork： env -u LD_LIBRARY_PATH $t"
}

# ── --purge：应急恢复（卸载 libmali + 摘全局注入），让 Xorg 回到 Mesa ────────
# 场景：装完 libmali 后重启，HDMI 一直刷 "use tmds mode"、桌面起不来。
# 该现象通常是 X/lightdm 在崩溃-重启死循环（每次重启都会重新 modeset HDMI），
# 而根源往往是本包安装的全局库注入让 Xorg 自己也去加载 libmali 的 EGL/GBM。
purge() {
	say "应急恢复：卸载 libmali + 摘掉全局注入（让 Xorg 重新用 Mesa）"
	local pkgs
	pkgs="$(dpkg-query -W -f='${Package}\n' 'libmali*' 2>/dev/null | tr '\n' ' ')"
	[[ -n "$pkgs" ]] && echo "  将卸载: $pkgs" || warn "未发现已安装的 libmali 包"
	echo "  将注释掉: $LDCONF（保留备份），并跑 ldconfig"
	confirm "继续？" || { echo "  已取消"; return 0; }

	if [[ -f "$LDCONF" ]]; then
		cp -a "$LDCONF" "${LDCONF}.bak.$(date +%Y%m%d-%H%M%S)"
		sed -i 's|^[[:space:]]*[^#].*|# &   # disabled by libmali-verify.sh --purge|' "$LDCONF"
		ok "已注释 $LDCONF（备份同名 .bak.*）"
	else
		echo "  $LDCONF 不存在，跳过"
	fi
	if [[ -n "$pkgs" ]]; then
		apt purge -y $pkgs || warn "purge 有告警，见上方输出"
		ok "已卸载 libmali（含它带来的 firmware / ICD / mali 包装库）"
	fi
	ldconfig 2>/dev/null
	command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload

	echo
	echo "  现在的库解析（应全部回到 Mesa/系统库）:"
	for _l in libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libGL.so.1; do
		printf "    %-16s -> %s\n" "$_l" "$(ldconfig -p 2>/dev/null | awk -v L="$_l" '$1==L{print $NF;exit}')"
	done
	ok "完成。下一步：sudo systemctl restart lightdm   （仍不行就 reboot）"
	echo "  起来后确认 X 用的是 Mesa："
	echo "    DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 glxinfo -B | grep -i renderer"
}

case "$DO" in
	probe)        probe ;;
	deep)         deep ;;
	nodisp)       nodisp ;;
	install-deb)  install_deb ;;
	unwire)       unwire ;;
	route)        route ;;
	which)        which_cmd ;;
	purge)        purge ;;
	env)          run_env ;;
	"")           status ;;
esac
