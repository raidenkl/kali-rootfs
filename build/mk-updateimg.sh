#!/bin/bash -e

# 打包 RKDevTool 可烧录的 update.img
# 用法:
#   ./mk-updateimg.sh                 # 默认 rk3576
#   ./mk-updateimg.sh rk356x          # 指定芯片: rk356x | rk3576 | rk3588
#   ./mk-updateimg.sh rk3588 emmc     # 指定烧录存储: emmc(默认) | sd | spinor ...
#
# 依赖:
#   build/rootfs.img            由 build/mk-image.sh 生成
#   build/firmware/{MiniLoaderAll.bin,uboot.img,boot.img}   见 build/firmware/README.md
#   tools/pack/{afptool,rkImageMaker}                       x86_64 静态二进制
#
# 流程(与 LubanCat_SDK 的 mk-updateimg.sh 一致):
#   afptool -pack   : 按 package-file 把各固件打成 AFP 容器 update.raw.img
#   rkImageMaker    : 套上带芯片标识的 RK 头部,得到 update.img

SCRIPT_DIR="$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"
PACK_TOOL="$REPO_DIR/tools/pack"
PARAM_DIR="$REPO_DIR/config/pack"
FW_DIR="$SCRIPT_DIR/firmware"
ROOTFS_IMG="$SCRIPT_DIR/rootfs.img"
OUT_DIR="$SCRIPT_DIR/update-img"
TARGET="$SCRIPT_DIR/update.img"

usage()
{
	echo "Usage: $0 [chip] [storage]"
	echo "  chip:    rk356x | rk3576 | rk3588  (default: rk3576)"
	echo "  storage: emmc | sd | spinor | spinand | sata | pcie  (default: emmc)"
	exit 1
}

CHIP="${1:-rk3576}"
STORAGE="${2:-emmc}"
PARAM="$PARAM_DIR/parameter-${CHIP}.txt"

case "$CHIP" in
	rk356x | rk3576 | rk3588) ;;
	*) echo "Error: unknown chip '$CHIP'"; usage ;;
esac

[ -f "$PARAM" ] || { echo "Error: parameter not found: $PARAM"; exit 1; }

# rootfs.img 常见误放位置: firmware/ 目录(与板级固件混在一起),自动纠正
if [ ! -f "$ROOTFS_IMG" ] && [ -f "$FW_DIR/rootfs.img" ]; then
	echo "Notice: found rootfs.img in $FW_DIR, moving to $SCRIPT_DIR/"
	mv -v "$FW_DIR/rootfs.img" "$ROOTFS_IMG"
fi

[ -f "$ROOTFS_IMG" ] || {
	echo "Error: $ROOTFS_IMG not found"
	echo "       run build/mk-image.sh first"
	exit 1
}
for f in MiniLoaderAll.bin uboot.img boot.img; do
	[ -f "$FW_DIR/$f" ] || {
		echo "Error: $FW_DIR/$f not found"
		echo "       see build/firmware/README.md to prepare firmware"
		exit 1
	}
done

echo "=== Packing update.img for $CHIP (storage: $STORAGE) ==="

rm -rf "$OUT_DIR" "$TARGET"
mkdir -p "$OUT_DIR"

# 汇集所有待打包固件
cp -v "$ROOTFS_IMG" "$OUT_DIR/rootfs.img"
for f in MiniLoaderAll.bin uboot.img boot.img; do
	cp -v "$FW_DIR/$f" "$OUT_DIR/$f"
done
cp -v "$PARAM" "$OUT_DIR/parameter.txt"

# package-file: NAME 必须与 parameter.txt CMDLINE 中的分区名一一对应
cat > "$OUT_DIR/package-file" << 'EOF'
# NAME	PATH
package-file	package-file
parameter	parameter.txt
bootloader	MiniLoaderAll.bin
uboot	uboot.img
boot	boot.img
rootfs	rootfs.img
EOF

cd "$OUT_DIR"

# 芯片标识存于 MiniLoaderAll.bin 偏移 21 字节处(如 RK35),动态读取避免写死
TAG="RK$(hexdump -s 21 -n 4 -e '4 "%c"' MiniLoaderAll.bin | rev)"
echo "Loader tag: $TAG"

"$PACK_TOOL/afptool" -pack ./ update.raw.img
"$PACK_TOOL/rkImageMaker" -"$TAG" MiniLoaderAll.bin \
	update.raw.img "$TARGET" -os_type:androidos -storage:"$STORAGE"

rm -f update.raw.img
cd "$REPO_DIR"

# 只保留 update.img,清理中间目录
rm -rf "$OUT_DIR"

echo ""
echo "=== Done ==="
echo "  Chip:    $CHIP"
echo "  Image:   $TARGET"
ls -lh "$TARGET"
echo ""
echo "Flash with RKDevTool:"
echo "  1. '升级固件' -> '固件' -> 选择本 update.img"
echo "  2. 板卡进 Maskrom/Loader 模式 -> '升级'"
echo "  (or use '下载镜像' tab for partition-level flashing)"
