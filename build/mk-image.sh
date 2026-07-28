#!/bin/bash -e

TARGET_ROOTFS_DIR="${1:-./rootfs}"
ROOTFSIMAGE="rootfs.img"

if [ ! -d "${TARGET_ROOTFS_DIR}" ]; then
	echo "Error: rootfs directory '${TARGET_ROOTFS_DIR}' not found"
	echo "Usage: $0 [rootfs_dir]"
	echo "       default rootfs dir: ./rootfs"
	exit 1
fi

echo "Making rootfs image from ${TARGET_ROOTFS_DIR}..."

if [ -e ${ROOTFSIMAGE} ]; then
	rm -f ${ROOTFSIMAGE}
fi

# Apparent size + maximum alignment(file_count * block_size) + maximum journal size
IMAGE_SIZE_MB=$(( $(sudo du --apparent-size -sm "${TARGET_ROOTFS_DIR}" | cut -f1) + \
	$(sudo find "${TARGET_ROOTFS_DIR}" | wc -l) * 4 / 1024 + 64 ))

# Extra 10% headroom
IMAGE_SIZE_MB=$(( $IMAGE_SIZE_MB * 110 / 100 ))

sudo mkfs.ext4 -O ^orphan_file -m 0 -d "${TARGET_ROOTFS_DIR}" "${ROOTFSIMAGE}" ${IMAGE_SIZE_MB}M

# Resize to minimum size
sudo e2fsck -p -f "${ROOTFSIMAGE}"
sudo resize2fs -M "${ROOTFSIMAGE}"

echo ""
echo "=== Done ==="
echo "  Image: ${ROOTFSIMAGE}"
ls -lh "${ROOTFSIMAGE}"
echo ""
echo "Write to root partition (e.g. mmcblk0p3):"
echo "  dd if=${ROOTFSIMAGE} of=/dev/mmcblk0pX bs=1M status=progress conv=fsync"