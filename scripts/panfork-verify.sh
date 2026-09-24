#!/bin/bash
# ============================================================================
# panfork-verify.sh —— 在【板卡上】执行：验证 panfork mesa 能否驱动 kbase GPU
#
# 这是「方案 A」的板卡侧操作脚本，与 scripts/check-gpu.sh（只读自检）配套：
#   check-gpu.sh      —— 看整条链路哪一层断了（只读）
#   panfork-verify.sh —— 只做 panfork 这一条线的安装/判定/回滚
#
# 用法（默认无参数＝只读体检）：
#   sudo bash panfork-verify.sh                  # 打印现状与下一步建议
#   sudo bash panfork-verify.sh --setup          # ① 装 PPA 公钥 + 给源加 Signed-By
#   sudo bash panfork-verify.sh --probe          # ② 只读：列出该 PPA 的 mesa 包与版本
#   sudo bash panfork-verify.sh --deps           # 只读：依赖体检（装不上时的原因通常在这两条）
#   sudo bash panfork-verify.sh --fix-llvm       # 从 Ubuntu jammy ports 补 libllvm14（唯一真障碍）
#   sudo bash panfork-verify.sh --install        # ③ 基线快照 + 最小化降级 + hold
#   sudo bash panfork-verify.sh --check          # ④ go/no-go 判定
#   sudo bash panfork-verify.sh --collect        # ⑤ 收集失败证据（只读）
#   sudo bash panfork-verify.sh --rollback       # ⑥ 回滚到 Kali 官方 mesa
#
#   附加开关：--yes 跳过确认；--key <文件> 用本地公钥而不联网抓取
#
# 背景：内核是 Arm kbase 闭源 DDK（/dev/mali0），Kali 自带 Mesa 26 的
#       panfrost 驱动配不上它 → GL 回退 llvmpipe。panfork 是唯一能配
#       kbase 的 mesa fork，但它基于 mesa 23.x，与本内核的 DDK g25p0
#       可能存在版本不兼容，故本脚本设计为可一键回滚。
# ============================================================================

FPR="0B2F0747E3BD546820A639B68065BE1FC67AABDE"
SRC=/etc/apt/sources.list.d/panfork.sources
KEYDIR=/etc/apt/keyrings
KEYASC="${KEYDIR}/panfork-mesa-ppa.asc"
KEYGPG="${KEYDIR}/panfork-mesa-ppa.gpg"
PIN=/etc/apt/preferences.d/panfork-mesa-ppa
PPA_URI="https://ppa.launchpadcontent.net/liujianfeng1994/panfork-mesa/ubuntu"
# 最小集：DRI 驱动 + GLX/EGL/GLAPI 的 Mesa 实现。以 --probe 的实际输出为准增补。
# 本次要降级的包：DRI 驱动 + GLX/EGL/GLAPI 的 Mesa 实现 + GBM（必须与 DRI 驱动同版）。
# 注：PPA 版本带 epoch（1:23.0.5 > 26.1.6），所以对 apt 而言是"升级"，但按 PIN 1001 会被优先选中。
MESA_PKGS="libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libglapi-mesa libgbm1"
# 同属 mesa 家族、PPA 里也有 panfork 版本，但本次【不降级】——降级它们对桌面 GL 无益，
# 反而会连带影响 Vulkan/VA-API。装完后统一 hold，避免被 apt upgrade 顺手降级。
PROTECT_PKGS="mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers libosmesa6 libgles2-mesa libgl1-mesa-glx libwayland-egl1-mesa mesa-opencl-icd"

DO="" ; ASSUME_YES=0 ; LOCAL_KEY=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--setup|--probe|--install|--check|--collect|--rollback|--deps|--fix-llvm|--verify) DO="${1#--}" ;;
		--yes|-y) ASSUME_YES=1 ;;
		--key) shift; LOCAL_KEY="${1:-}" ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		*) echo "未知参数: $1（用 --help 看用法）"; exit 2 ;;
	esac
	shift
done

say()  { echo -e "\e[1;36m== $* ==\e[0m"; }
ok()   { echo -e "  \e[32m[OK]\e[0m   $*"; }
warn() { echo -e "  \e[33m[WARN]\e[0m $*"; }
bad()  { echo -e "  \e[31m[FAIL]\e[0m $*"; }
die()  { echo -e "\e[31mERROR: $*\e[0m" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "请用 root 运行（sudo bash $0 ${DO:+--$DO}）"

confirm() {
	[[ "$ASSUME_YES" == "1" ]] && return 0
	echo
	read -r -p "  $1 [y/N] " a
	[[ "$a" == "y" || "$a" == "Y" ]]
}

# ── X 凭据解析（今天的教训：转发显示 / cookie 位置都会让 GL 测试假失败）──────
is_forwarded_display() { [[ -n "$DISPLAY" && "$DISPLAY" =~ ^[^:]+: ]]; }
xorg_auth_path() {
	command -v ps >/dev/null 2>&1 || return 0
	ps -eo args 2>/dev/null | grep -E '[X]org' | head -3 \
		| sed -n 's/.*-auth[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -1
}
ensure_x() {
	local target="$DISPLAY"
	if is_forwarded_display; then
		warn "DISPLAY=$DISPLAY 是转发的 X（ssh/MobaXterm）：GL 测试会假失败，改试本地 :0"
		target=":0"
	fi
	command -v xset >/dev/null 2>&1 || { warn "缺 xset（apt install x11-xserver-utils），无法验证 X 可达"; return 1; }
	local c
	local -a cands=("$(xorg_auth_path)" "" "$HOME/.Xauthority" /root/.Xauthority /var/run/lightdm/root/:0)
	cands+=($(ls /home/*/.Xauthority /run/user/*/gdm/Xauthority /run/user/*/.mutter-Xwaylandauth.* 2>/dev/null))
	for c in "${cands[@]}"; do
		if [[ -z "$c" ]]; then
			if env -u XAUTHORITY DISPLAY="$target" timeout 8 xset q >/dev/null 2>&1; then
				unset XAUTHORITY; export DISPLAY="$target"
				echo "  X 可达：本地 $target（默认 XAUTHORITY）"; return 0
			fi
		elif [[ -r "$c" ]] && DISPLAY="$target" XAUTHORITY="$c" timeout 8 xset q >/dev/null 2>&1; then
			export DISPLAY="$target" XAUTHORITY="$c"
			echo "  X 可达：本地 $target，XAUTHORITY=$c"; return 0
		fi
	done
	export DISPLAY="$target"
	return 1
}

# 取到当前 mesa 相关包的版本，供前后对比
mesa_versions() {
	dpkg-query -W -f='  ${Package} ${Version}\n' $MESA_PKGS 2>/dev/null
	for b in libgbm1; do
		dpkg-query -W -f="  \${Package} \${Version}\n" "$b" 2>/dev/null
	done
}

# ── 0 体检（无参数时的行为）────────────────────────────────────────────────
status() {
	say "当前状态"
	echo "  内核: $(uname -r)"
	local g=""
	dmesg 2>/dev/null | grep -qi 'Probed as mali0' && ok "/dev/mali0 已就绪（kbase 探测成功）" \
		|| bad "kbase 未探测成功 —— 先修内核侧，本脚本不适用"
	g="$(dmesg 2>/dev/null | grep -i 'Kernel DDK version' | tail -1)"
	[[ -n "$g" ]] && echo "  ${g#*] }"
	echo "  PPA 源:  $([[ -f "$SRC" ]] && echo "已存在 $SRC" || echo "未配置")"
	echo "  公钥:    $([[ -f "$KEYGPG" || -f "$KEYASC" ]] && echo "已安装" || echo "未安装")"
	echo "  pin:     $([[ -f "$PIN" ]] && grep -h Pin-Priority "$PIN" || echo "缺失（降级不会被优先选中）")"
	mesa_versions
	if command -v glxinfo >/dev/null 2>&1 && [[ -n "$DISPLAY" ]]; then
		local r; r="$(timeout 20 glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer string/{print $2}')"
		[[ -n "$r" ]] && echo "  当前渲染器: $r"
	fi
	say "下一步"
	if [[ ! -f "$SRC" || ! -f "$KEYGPG" && ! -f "$KEYASC" ]]; then
		echo "  → sudo bash $0 --setup     # 配置源与公钥"
	else
		echo "  → sudo bash $0 --probe     # 看 PPA 提供了哪些包"
		echo "  → sudo bash $0 --install   # 最小化降级"
		echo "  → sudo bash $0 --check     # 判定"
	fi
}

# ── 1 配置源 + 公钥 ────────────────────────────────────────────────────────
setup() {
	say "① 安装 PPA 公钥与源配置"
	install -d -m 0755 "$KEYDIR"

	# 公钥来源优先级：--key 指定 > 仓库预置文件 > 联网抓取
	local cands=("$LOCAL_KEY" "./panfork-mesa-archive-keyring.asc"
		"../overlay/usr/share/keyrings/panfork-mesa-archive-keyring.asc"
		"/usr/share/keyrings/panfork-mesa-archive-keyring.asc")
	local got=""
	for c in "${cands[@]}"; do
		[[ -n "$c" && -f "$c" ]] && got="$c" && break
	done
	if [[ -n "$got" ]]; then
		cp -f "$got" "$KEYASC" && ok "使用本地公钥: $got"
	else
		local urls=(
			"https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${FPR}"
			"https://api.launchpad.net/1.0/~liujianfeng1994/+archive/ubuntu/panfork-mesa?ws.op=getSigningKeyData"
		)
		for u in "${urls[@]}"; do
			if command -v curl >/dev/null 2>&1; then
				curl -fsSL "$u" -o "$KEYASC" && break
			elif command -v wget >/dev/null 2>&1; then
				wget -qO "$KEYASC" "$u" && break
			else
				die "既无 curl 也无 wget，且未提供本地公钥（--key <文件>）"
			fi
		done
		grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$KEYASC" 2>/dev/null \
			&& ok "已从 keyserver/Launchpad 抓取公钥" \
			|| die "公钥抓取失败（网络受限？可用 --key 指定本地文件后重试）"
	fi

	# 校验指纹，必须与 apt 报错里的 key 一致
	local signed_by="$KEYASC"
	if command -v gpg >/dev/null 2>&1; then
		if gpg --dearmor -o "$KEYGPG" < "$KEYASC" 2>/dev/null; then
			signed_by="$KEYGPG"
			gpg --show-keys --with-fingerprint "$KEYGPG" 2>/dev/null | sed 's/^/    /'
			if gpg --show-keys --with-fingerprint "$KEYGPG" 2>/dev/null | tr -d ' ' | grep -qi "$FPR"; then
				ok "指纹匹配 ${FPR}"
			else
				warn "指纹未匹配 ${FPR}，装包前请人工核对上面的指纹"
			fi
		fi
	fi

	# 写 deb822 源：去掉 Trusted: yes（整源免验签），改 Signed-By（精确验签）
	cat > "$SRC" <<EOF
Types: deb
URIs: ${PPA_URI}
Suites: jammy
Components: main
Architectures: arm64
Signed-By: ${signed_by}
EOF
	ok "已写入 $SRC（Signed-By: ${signed_by}）"

	echo
	echo "  apt update 输出（期望：无 Warning、无 Notice）:"
	apt-get update 2>&1 | sed 's/^/    /'
}

# ── 2 只读探查 ─────────────────────────────────────────────────────────────
probe() {
	say "② 该 PPA 提供的 mesa 包（装之前先看清楚）"
	echo "  --- 按 origin 列出 ---"
	local listed
	listed="$(apt list -a '?origin(LP-PPA-liujianfeng1994-panfork-mesa)' 2>/dev/null | grep -v '^$' | grep -v '^Listing')"
	if [[ -n "$listed" ]]; then
		echo "$listed" | sed 's/^/    /'
	else
		echo "    （该查询无结果或语法不被支持，以下面的 policy 为准）"
	fi
	echo "  --- 候选版本 ---"
	apt-cache policy $MESA_PKGS libgbm1 2>/dev/null | sed 's/^/    /'
	echo
	warn "确认上面是否出现 panfork 的 23.x，且候选来自 LP-PPA-liujianfeng1994-panfork-mesa。"
	echo
	echo "  本脚本要装的（定向降级）:"
	echo "    $MESA_PKGS"
	echo "  不动的（装完会 hold 在 26.x）:"
	echo "    $PROTECT_PKGS"
	echo
	echo "  另注：这个 PPA 里还有几个与 libmali 路线相关的包，本次不装、先记下——"
	echo "    libdri2to3        DRI2→DRI3 转译层（很可能正是 libmali 在 X11 下缺的那一块）"
	echo "    libmali-g610-x11  libmali 的 X11 变体；malirun 按需运行 libmali 的包装器"
	echo "    mali-g610-firmware  GPU 固件包（替代手动装 deb 里的 firmware）"
	echo "  若 panfork 失败想回 libmali 路线，可用“libdri2to3 + libmali-g610-x11 + malirun“再试一次 X11"
	echo "  （这比我们手搓 LD_LIBRARY_PATH 更正统，且不必全局注入，不会破坏 Xorg）"
}

# ── 2.5 依赖体检 ───────────────────────────────────────────────────────────
# panfork 的 mesa 是 jammy 期构建，硬依赖 libllvm14；同时依赖 PPA 里的 mali-g610-firmware。
# 前者 Kali 已没有，后者可能与厂商 libmali deb 争同一个固件文件 —— 这两条就是装不上的常见原因。
deps() {
	say "依赖体检"
	echo "  --- libllvm14（llvmpipe/swrast 用；panfrost 本身不需要，但 dpkg 的 Depends 要求）---"
	apt-cache policy libllvm14 2>/dev/null | sed 's/^/    /'
	local c14
	c14="$(apt-cache policy libllvm14 2>/dev/null | awk '/Candidate:/{print $2}')"
	[[ -z "$c14" || "$c14" == "(none)" ]] \
		&& bad "libllvm14 不可用 → 需要从 Ubuntu jammy ports 补，或用 dpkg --force-depends 绕过" \
		|| ok "libllvm14 可用: $c14"

	echo
	echo "  --- mali-g610-firmware（PPA 提供，panfork 的 mesa 依赖它）---"
	apt-cache policy mali-g610-firmware 2>/dev/null | sed 's/^/    /'
	apt-get install -s mali-g610-firmware 2>&1 | tail -8 | sed 's/^/    /'

	echo
	echo "  --- 板上现有 libmali / 固件归属（判断是否与 mali-g610-firmware 抢文件）---"
	dpkg -l 2>/dev/null | grep -i mali | sed 's/^/    /'
	ls -l /lib/firmware/mali_csffw.bin 2>&1 | sed 's/^/    /'
	dpkg -S /lib/firmware/mali_csffw.bin 2>&1 | sed 's/^/    /'

	say "结论与下一步"
	cat <<'TIP'
  实测结论（本板）：mali-g610-firmware 装得干净（dry-run: 0 upgraded, 1 newly installed），
  之前那句 "not going to be installed" 只是 libllvm14 让整个求解失败后的连带报错。
  所以真障碍只有一个：libllvm14。

  → sudo bash $0 --fix-llvm    # 从 jammy ports 临时取 libllvm14（低优先级 pin + 装完删源）
  → sudo bash $0 --install     # 再装 panfork
  → sudo systemctl restart lightdm && sudo bash $0 --check

  若真实安装时 dpkg 报固件文件被占用（trying to overwrite /lib/firmware/mali_csffw.bin）：
      sudo dpkg -i --force-overwrite /var/cache/apt/archives/mali-g610-firmware*.deb
  若想彻底避免这一层：卸掉厂商包，route C 改用 PPA 的 libmali-g610-x11 + libdri2to3 + malirun
      sudo apt purge -y libmali-valhall-g610-g24p0-x11-gbm
TIP
}

# ── 2.6 补 libllvm14（panfork mesa 唯一的真障碍）────────────────────────────
# panfork 的 mesa 是 jammy 期构建，Depends: libllvm14（只给 llvmpipe/swrast 用，
# panfrost 走 NIR 不需要它）。Kali rolling 已无此包 → 从 Ubuntu jammy ports 临时取。
# 用【低优先级 pin(100)】+【装完立刻删源】把污染面压到最小：100 表示只在该包
# 于其它源不可得时才采用，绝不会把 Kali 的包升级成 jammy 版。
fix_llvm() {
	say "补 libllvm14（来自 Ubuntu jammy ports）"
	if apt-cache policy libllvm14 2>/dev/null | awk '/Candidate:/{print $2}' | grep -qv '(none)'; then
		ok "libllvm14 已可用，无需处理"; return 0
	fi
	local tmp=/etc/apt/sources.list.d/ubuntu-jammy-temp.list
	local pin=/etc/apt/preferences.d/ubuntu-jammy-temp
	cat > "$tmp" <<'EOF'
deb [trusted=yes] https://mirrors.aliyun.com/ubuntu-ports jammy main universe
EOF
	cat > "$pin" <<'EOF'
Package: *
Pin: release n=jammy
Pin-Priority: 100
EOF
	ok "已加临时源（pin 100 兜底）：$tmp"
	apt-get update 2>&1 | tail -3 | sed 's/^/    /'

	local prev
	prev="$(apt-get install -s libllvm14 2>&1)"
	echo "  预演（dry-run）："
	echo "$prev" | grep -E '^(Inst|Conf|Remv|E:)' | sed 's/^/    /'
	if echo "$prev" | grep -q '^Remv '; then
		warn "预演里出现了 Remv —— 可能有包被移除，请人工确认后再继续"
	fi
	echo
	warn "期望：Inst 里只有 libllvm14 及其缺失依赖，不出现任何 Kali 包被降级/移除"
	confirm "继续安装？" || {
		rm -f "$tmp" "$pin"; apt-get update >/dev/null 2>&1
		echo "  已取消，并清理临时源"; return 0
	}

	apt-get install -y libllvm14 || warn "安装失败，见上方输出"
	rm -f "$tmp" "$pin"
	apt-get update 2>&1 | tail -2 | sed 's/^/    /'
	ok "已删除临时源与 pin（jammy 不会继续参与后续 apt 解析）"
	apt-mark hold libllvm14 >/dev/null 2>&1 && echo "  已 hold libllvm14（它只服务于 panfork，避免被误删）"
	dpkg -l libllvm14 2>/dev/null | tail -1 | sed 's/^/    /'
	echo
	echo "  下一步：sudo bash $0 --install"
}

# ── 3 基线 + 最小化降级 ────────────────────────────────────────────────────
install_mesa() {
	say "③ 基线快照 + 最小化降级"
	dpkg -l | grep -iE 'mesa|libgl|libegl|libgbm' > /root/mesa-before.txt
	ok "基线已存 /root/mesa-before.txt"

	echo "  拟安装/降级: $MESA_PKGS"
	local preview hlist
	preview="$(apt-get install -s --allow-downgrades $MESA_PKGS 2>&1)"
	echo "  预演（--dry-run，不改动系统）："
	echo "$preview" | grep -E '^(Inst|Remv|E:)' | sed 's/^/    /' | head -40
	hlist="$(echo "$preview" | awk '/^Inst /{print $2}' | tr '\n' ' ')"
	echo
	warn "此举会把 Kali 的 Mesa 26 换成 panfork 的 23.x，且可能连带降级依赖包（见上面预演）。"
	confirm "继续？" || { echo "  已取消"; exit 0; }

	apt-get install -y --allow-downgrades $MESA_PKGS || die "安装失败，见上方 apt 输出"

	# hold 所有被降级的包（含连带降级的依赖），否则下次 apt upgrade 会被升回 26
	[[ -n "$hlist" ]] || hlist="$MESA_PKGS"
	apt-mark hold $hlist >/dev/null && ok "已 hold: $hlist"

	# 顺手 hold 住同家族里我们不想动的包（PPA 里也有它们的 panfork 版，不 hold 会被 apt upgrade 降级）
	# 注意：这些包可能已被本次安装"连带降级"（如 mesa-vulkan-drivers），下面的版本检查会如实指出
	local p pv
	for p in $PROTECT_PKGS; do
		if dpkg -s "$p" >/dev/null 2>&1; then
			apt-mark hold "$p" >/dev/null 2>&1
			pv="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
			case "$pv" in
				*panfork*) warn "hold（已被连带降级到 panfork 版，非计划内）: $p $pv" ;;
				*)         echo "  hold（保持 26.x 不动）: $p" ;;
			esac
		fi
	done
	echo
	mesa_versions
	echo
	echo "  origin 核对（应出现 LP-PPA-liujianfeng1994-panfork-mesa）:"
	apt-cache policy $MESA_PKGS 2>/dev/null | grep -E '^[a-z]|Installed|Candidate|origin|LP-PPA' | sed 's/^/    /'
	echo
	warn "下一步：重启 X 让新驱动生效（已在跑的进程不会换驱动）"
	echo "    sudo systemctl restart lightdm    # 桌面起不来就 systemctl isolate multi-user.target"
	echo "  然后：sudo bash $0 --check"
}

# ── 4 go/no-go ─────────────────────────────────────────────────────────────
check() {
	say "④ go/no-go 判定"
	# X 凭据必须先解析对，否则 glxinfo 取不到会被误判成"panfork 没生效"
	if [[ -z "$DISPLAY" ]]; then
		warn "无 DISPLAY：请在本机桌面会话里跑，或先 export DISPLAY=:0"
	else
		ensure_x || warn "X 不可达 —— glxinfo 必然失败，这【不能】当作 panfork 没生效的证据"
	fi

	local r=""
	r="$(timeout 20 glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer string/{print $2}')"

	echo "  mesa 版本："; mesa_versions
	[[ -n "$r" ]] && echo "  OpenGL renderer = $r"

	# kbase DDK 版本不兼容的特征（panfork 是旧 DDK 用户态）
	local ddk_bad=0
	if { dmesg 2>/dev/null; journalctl -b --no-pager 2>/dev/null; } | \
	   grep -qiE 'not of a compatible version|DDK version mismatch|Kernel DDK.*mismatch'; then
		ddk_bad=1
	fi
	if grep -qiE 'not of a compatible version|DDK version' /var/log/Xorg.0.log 2>/dev/null; then
		ddk_bad=1
	fi

	say "结论"
	if [[ -n "$r" ]] && echo "$r" | grep -qiE 'Mali|Panfrost|Panthor'; then
		ok "GO —— 走的是 Mali 硬件渲染"
		echo "  默认路径核对（应指向 /usr/lib/aarch64-linux-gnu/，不是 mali/）："
		for _l in libGL.so.1 libEGL.so.1 libGLESv2.so.2; do
			printf "    %-16s -> %s\n" "$_l" "$(ldconfig -p 2>/dev/null | awk -v L="$_l" '$1==L{print $NF;exit}')"
		done
		echo "  完整验证（推荐）：sudo bash $0 --verify   # 压测 + X 存活 + OpenCL 共存"
		command -v glmark2-es2 >/dev/null 2>&1 || echo "  未装：apt install glmark2-es2"
		echo "  与 libmali 共存自检：sudo bash libmali-verify.sh --nodisp   （应仍能看到 Mali）"
	elif [[ "$ddk_bad" == "1" ]]; then
		bad "NO-GO（DDK 不兼容）—— panfork(旧 DDK 用户态) 与内核 kbase 对不上"
		echo "  → sudo bash $0 --collect    # 留证据"
		echo "  → sudo bash $0 --rollback   # 回滚"
	elif [[ -n "$r" ]] && echo "$r" | grep -qiE 'llvmpipe|softpipe|swrast'; then
		bad "NO-GO —— 仍是 llvmpipe 软件渲染"
		echo "  依次确认：① 上面有没有出现 'X 可达'（没出现先修 X 凭据，别急着甩锅驱动）"
		echo "            ② mesa 版本是否已降到 panfork 的 23.x（见上方）"
		echo "  若版本没变 → 回到 --probe 检查 pin / PPA 来源"
		echo "  若版本已变但仍 llvmpipe → sudo bash $0 --collect 后回滚"
	else
		warn "无法判定（拿不到 renderer）—— 请在桌面会话里重跑 --check"
	fi
}

# ── 4.5 完整验证：装好之后，GPU 到底能不能正常工作 ─────────────────────────
# 分六段，任何一段断了就是根因所在：
#   ① 内核/设备 ② 驱动归属 ③ X 与桌面 GL ④ 压测（得分 + 负载 + X 是否存活）
#   ⑤ 计算通路共存（OpenCL，不需要显示器）⑥ 无 X 的 DRM/GBM 直出（给出命令，不自动执行）
gpu_devfreq() {
	local d
	d="$(ls -d /sys/class/devfreq/*gpu* 2>/dev/null | head -1)"
	[[ -z "$d" ]] && d=/sys/devices/platform/fb000000.gpu/devfreq/fb000000.gpu
	[[ -d "$d" ]] && echo "$d"
}

# 只挑 mali 的"真错误"。启动期那些 `is capped from`（超时被限制）、
# `kbase_mmap_min_addr compiled to ...` 都是正常提示，按关键词粗筛会全部误报。
mali_errors() {
	dmesg 2>/dev/null | grep -iE 'mali|csf' \
		| grep -viE 'is capped from|mmap_min_addr|Kernel DDK version|Probed as mali0|GPU identified|Mali device registered|Kernel config:' \
		| grep -iE 'fault|error|fail|reset|panic|oops|stuck|not responding|timed out'
}

verify() {
	say "GPU 完整验证（在 --check 之上补压测、X 存活与共存检查）"
	local df; df="$(gpu_devfreq)"
	local glog=/tmp/glmark2-verify.log
	local loadlog=/tmp/mali-load-verify.log
	local R="" VEND="" VER="" SCORE="" GO=1

	# ── ① 内核与设备 ──────────────────────────────────────────────────────
	echo "  [1/6] 内核与设备"
	if dmesg 2>/dev/null | grep -qi 'Probed as mali0'; then
		ok "kbase 就绪（Probed as mali0，/dev/mali0 在）"
	else
		bad "kbase 未探测成功 —— 先修内核侧，与 panfork 无关"
		GO=0
	fi
	dmesg 2>/dev/null | grep -i 'Kernel DDK version' | tail -1 | sed 's/^/    /'
	if [[ -n "$df" ]]; then
		echo "    devfreq: $df"
		echo "    governor=$(cat "$df/governor" 2>/dev/null)  cur_freq=$(cat "$df/cur_freq" 2>/dev/null) Hz"
	else
		warn "未找到 GPU devfreq 节点（不影响功能，只是看不到负载/频率）"
	fi

	# ── ② 驱动归属 ────────────────────────────────────────────────────────
	echo "  [2/6] 驱动归属（默认路径应为系统目录，不是 mali/）"
	dpkg-query -W -f='    ${Package} ${Version}\n' $MESA_PKGS 2>/dev/null
	local hit
	for _l in libGL.so.1 libEGL.so.1 libGLESv2.so.2; do
		hit="$(ldconfig -p 2>/dev/null | awk -v L="$_l" '$1==L{print $NF;exit}')"
		printf "    %-14s -> %s\n" "$_l" "$hit"
		case "$hit" in
			*"/mali/"*) bad "↑ 被 libmali 接管：Xorg 会 fatal（glamor GLSL 编译失败），请先 --unwire"; GO=0 ;;
		esac
	done

	# ── ③ X 与桌面 GL ─────────────────────────────────────────────────────
	echo "  [3/6] X 与桌面 GL"
	[[ -z "$DISPLAY" ]] && export DISPLAY=:0
	local xok=1
	ensure_x || { warn "X 不可达：下一段 GL 结果不可用（先修凭据，别甩锅驱动）"; xok=0; }
	if command -v glxinfo >/dev/null 2>&1; then
		local gb
		gb="$(timeout 25 glxinfo -B 2>/dev/null)"
		R="$(echo "$gb" | awk -F': ' '/OpenGL renderer string/{print $2}')"
		VEND="$(echo "$gb" | awk -F': ' '/OpenGL vendor string/{print $2}')"
		VER="$(echo "$gb" | awk -F': ' '/OpenGL version string/{print $2}')"
		local acc; acc="$(echo "$gb" | awk -F': ' '/Accelerated:/{print $2}')"
		echo "    vendor=$VEND"
		echo "    version=$VER"
		echo "    renderer=$R"
		[[ -n "$acc" ]] && echo "    Accelerated=$acc"
	else
		warn "未装 glxinfo（apt install mesa-utils）"
	fi
	if echo "$R" | grep -qiE 'Panfrost|Mali|Panthor'; then
		ok "桌面 GL 走 Mali 硬件（$R）"
	elif echo "$R" | grep -qiE 'llvmpipe|softpipe|swrast'; then
		[[ "$xok" == "1" ]] && bad "桌面 GL 仍是 $R（软渲染）" || warn "renderer=$R，但 X 不可达，此结果不算证据"
		[[ "$xok" == "1" ]] && GO=0
	elif [[ -n "$R" ]]; then
		warn "渲染器无法识别: $R"
	fi
	if [[ -f /var/log/Xorg.0.log ]]; then
		grep -iE 'glamor' /var/log/Xorg.0.log 2>/dev/null | tail -3 | sed 's/^/    Xorg: /'
		if grep -qi 'Refusing to try glamor on llvmpipe' /var/log/Xorg.0.log 2>/dev/null; then
			warn "Xorg 日志里仍有 'Refusing to try glamor on llvmpipe'（可能是上一次会话的旧日志，确认时间戳）"
		fi
		grep -qiE 'GLSL compile failure|Fatal server error' /var/log/Xorg.0.log 2>/dev/null \
			&& bad "Xorg 有过 fatal（见上）——多半是 libmali 全局注入还在生效"
	fi

	# ── ④ 压测 ────────────────────────────────────────────────────────────
	echo "  [4/6] 压测 glmark2-es2（窗口模式，本机 X）"
	if command -v glmark2-es2 >/dev/null 2>&1 && [[ "$xok" == "1" ]]; then
		local dur="${GLMARK_DURATION:-2}"
		: > "$loadlog"; : > "$glog"
		echo "    duration=${dur}s/场景（GLMARK_DURATION 可调）..."
		timeout 600 glmark2-es2 -b :duration="$dur" >"$glog" 2>&1 &
		local pid=$! i=0
		while kill -0 "$pid" 2>/dev/null; do
			[[ -n "$df" ]] && cat "$df/load" 2>/dev/null >> "$loadlog"
			sleep 1
			i=$((i+1)); [[ $i -gt 300 ]] && break
		done
		wait "$pid" 2>/dev/null

		# 注意：-F': ' 不剥字段尾部空白，glmark2 的输出带前导/尾随空格 → 必须显式清理，
		# 否则 SCORE="1156 " 之类的值会让数值比较和正则判定全部失效。
		local gr; gr="$(sed -n 's/.*GL_RENDERER:[[:space:]]*//p' "$glog" | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
		SCORE="$(sed -n 's/.*glmark2 Score:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$glog" | tail -1 | tr -d '[:space:]')"
		echo "    压测渲染器: ${gr:-（取不到）}"
		echo "    得分: ${SCORE:-（取不到）}"
		echo "    参考：panfrost(panfork) 约 1000~1600；闭源 blob 约 2000~2400；llvmpipe 约 40"
		if [[ -n "$df" && -s "$loadlog" ]]; then
			echo "    压测期间 GPU 负载/频率采样: $(sort -u "$loadlog" | tr '\n' ' ')"
			echo "    （governor=performance 已锁最高频时，频率不变属正常，看负载数值）"
		fi
		if grep -qiE 'X connection to .* broken|Could not initialize canvas|fatal IO error' "$glog"; then
			bad "压测中途 X 连接断开/未能初始化（详见 $glog）"
			echo "      → 这通常意味着「把 GPU 渲染的帧交给 stock Xorg」这条路不通"
			GO=0
		elif [[ "$SCORE" =~ ^[0-9]+$ ]]; then
			if [[ "$SCORE" -ge 1000 ]]; then
				ok "得分在 panfrost 的合理区间（panfrost 比闭源 blob 慢约一半，属正常）"
			elif [[ "$SCORE" -ge 300 ]]; then
				warn "得分低于 panfrost 常见区间（1000+）——查散热/降频、X 合成开销、是否被 llvmpipe 兜底"
			else
				bad "得分接近软渲染水平，跑的可能仍是 llvmpipe"
				GO=0
			fi
		elif [[ -n "$SCORE" ]]; then
			warn "得分无法解析: $SCORE"
		fi
		echo "$gr" | grep -qiE 'Panfrost|Mali' || { bad "压测渲染器不是 Mali"; GO=0; }
	else
		command -v glmark2-es2 >/dev/null 2>&1 || echo "    未装 glmark2-es2（apt install glmark2-es2）"
		[[ "$xok" != "1" ]] && echo "    X 不可达，跳过（这就是之前几轮假失败的根源）"
	fi
	local merr; merr="$(mali_errors)"
	if [[ -n "$merr" ]]; then
		echo "$merr" | tail -5 | sed 's/^/    /'
		warn "上面是 mali 的错误行，请人工判断"
	else
		ok "dmesg 无 mali 报错（启动期的 'is capped from' / mmap_min_addr 等提示已按正常过滤）"
	fi

	# ── ⑤ 计算通路共存（不需要显示器，最适合出厂验证）──────────────────────
	echo "  [5/6] 计算通路共存（OpenCL，无需显示）"
	local MDIR=/usr/lib/aarch64-linux-gnu/mali
	if command -v clinfo >/dev/null 2>&1; then
		local co; co="$(timeout 90 clinfo 2>/dev/null)"
		if ! echo "$co" | grep -qi 'Mali'; then
			# panfork 装好后 mali 目录通常【不在】默认搜索路径里（那正是刻意摘掉全局注入的结果），
			# 于是 ICD 里写的 libMaliOpenCL.so.1 解析不到 → 显式带上路径重试一次。
			local co2; co2="$(timeout 90 env LD_LIBRARY_PATH="$MDIR" clinfo 2>/dev/null)"
			if echo "$co2" | grep -qi 'Mali'; then
				co="$co2"
				echo "    默认路径找不到 libMaliOpenCL.so.1；显式 LD_LIBRARY_PATH=$MDIR 后可用"
				echo "    → 这不是故障：全局注入是被刻意关掉的（开着会让 Xorg fatal）"
				echo "    → 要让 OpenCL/Vulkan 免设置可用： sudo bash libmali-verify.sh --route"
			fi
		fi
		if echo "$co" | grep -qi 'Mali-G610'; then
			ok "OpenCL 能枚举 Mali（libmali 的按需通路完好，与 panfork 共存正常）"
			echo "$co" | grep -iE '^\s*(Device Name|Device Version)' | head -2 | sed 's/^/    /'
		else
			warn "OpenCL 未看到 Mali（若你不需要 libmali 的计算通路，可忽略；需要就跑 --route 看办法）"
		fi
	else
		warn "未装 clinfo（apt install clinfo）——它不需要显示器，建议装来做出厂验证"
	fi

	# ── ⑥ 无 X 的 DRM/GBM 直出（不自动执行，避免打断桌面）──────────────────
	echo "  [6/6] 无 X 的 DRM/GBM 直出（可选，需短暂停 lightdm）"
	if command -v kmscube >/dev/null 2>&1; then
		echo "    sudo systemctl stop lightdm"
		echo "    sudo env -u DISPLAY LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu/mali kmscube"
		echo "    sudo systemctl start lightdm   # 验完务必执行"
	else
		echo "    apt install kmscube   # 装完按上面三步测（HDMI 上会看到旋转立方体）"
	fi

	# ── 汇总 ──────────────────────────────────────────────────────────────
	say "验证汇总"
	if [[ "$GO" == "1" ]]; then
		if [[ -n "$SCORE" ]]; then
			ok "GPU 正常：桌面 GL 走 Mali 硬件，glmark2 得分 $SCORE（对照：软渲染约 40）"
		else
			ok "GPU 正常：桌面 GL 走 Mali 硬件"
		fi
		[[ -n "$R" ]] && echo "    renderer = $R"
		echo "    能力：X11 桌面 GL / GLX / GLES / Vulkan"
		echo "    注意：mesa 已从 26.1.6 降到 panfork 的 23.x，相关包已 hold，别解除"
	else
		bad "存在未通过项，按上面标红的那一段定位；X 不可达时 GL 失败不算驱动证据"
		echo "    → sudo bash $0 --collect     # 留证据"
		echo "    → sudo bash $0 --rollback    # 回滚"
	fi
	echo
	echo "  判定口诀："
	echo "    ③ 出现 Mali-G610 (Panfrost)  = 桌面 GL 已硬件加速"
	echo "    ④ 得分 1500~2300 且 X 存活   = 呈现路径可用"
	echo "    ⑤ clinfo 能看到 Mali-G610    = 计算通路（libmali）与 panfork 共存良好"
}

# ── 5 收集证据 ─────────────────────────────────────────────────────────────
collect() {
	say "⑤ 收集证据"
	dmesg 2>/dev/null | grep -iE 'mali|kbase|DDK|csf' | tail -40 > /root/gpu-fail-dmesg.txt
	{
		echo "### journal (Xorg/glamor/EGL/mali)"
		journalctl -b --no-pager 2>/dev/null | grep -iE 'Xorg|glamor|EGL|mali|panfrost' | tail -40
		echo; echo "### Xorg.0.log"
		grep -iE 'glamor|Mali|DDK|EE\)' /var/log/Xorg.0.log 2>/dev/null | tail -30
		echo; echo "### dpkg / ldd / mali debugfs"
		dpkg -l | grep -iE 'mesa|mali|libgl|libegl|libgbm'
		ldd /usr/lib/aarch64-linux-gnu/libEGL.so.1 2>/dev/null
		cat /sys/kernel/debug/mali0/version 2>/dev/null
		echo; echo "### libmali 现状（决定失败后走哪条后路）"
		dpkg -S /usr/lib/aarch64-linux-gnu/libmali-hook.so.1.9.0 2>/dev/null
		find /usr/lib -maxdepth 3 -name 'libmali*.so*' -size +5M 2>/dev/null
		ls -l /lib/firmware/mali_csffw.bin 2>/dev/null
	} > /root/gpu-fail-journal.txt
	ok "已写入 /root/gpu-fail-dmesg.txt 与 /root/gpu-fail-journal.txt"
	echo
	echo "  后路判据："
	if find /usr/lib -maxdepth 3 -name 'libmali*.so*' -size +5M 2>/dev/null | grep -q .; then
		echo "    发现 >5MB 的 libmali 实体 blob → 可转 libmali 路线（与 kbase 同源的闭源用户态）"
	else
		echo "    只有 libmali-hook 没有实体 blob → 建议转「换带 panthor 的内核」"
	fi
}

# ── 6 回滚 ─────────────────────────────────────────────────────────────────
rollback() {
	say "⑥ 回滚到 Kali 官方 mesa"
	collect
	warn "将删除 PPA 源/公钥/pin，并把 mesa 装回 Kali 源的版本。"
	confirm "继续？" || { echo "  已取消"; exit 0; }

	apt-mark unhold $MESA_PKGS $PROTECT_PKGS 2>/dev/null
	rm -f "$SRC" "$KEYGPG" "$KEYASC" "$PIN"
	ok "已删除 $SRC / 公钥 / pin"
	apt-get update 2>&1 | tail -3 | sed 's/^/    /'
	# 只装回"Kali 源里确实有候选"的包（如 libglapi-mesa 在 Kali 里不存在，跳过即可）
	local av=()
	local p
	for p in $MESA_PKGS; do
		if apt-cache policy "$p" 2>/dev/null | grep -qE 'Candidate: \(none\)'; then
			echo "  跳过（Kali 源无此包）: $p"
		else
			av+=("$p")
		fi
	done
	apt-get install -y --allow-downgrades "${av[@]}" || warn "装回失败，检查上方 apt 输出"
	echo
	mesa_versions
	ok "回滚完成，建议 reboot 后核对：glxinfo -B 应回到 llvmpipe（即改动前状态）"
}

case "$DO" in
	setup)    setup ;;
	deps)     deps ;;
	fix-llvm) fix_llvm ;;
	probe)    probe ;;
	install)  install_mesa ;;
	check)    check ;;
	verify)   verify ;;
	collect)  collect ;;
	rollback) rollback ;;
	"")       status ;;
esac
