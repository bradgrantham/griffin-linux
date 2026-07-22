#!/bin/sh
# Assemble the bootable Griffin CompactFlash image from already-built pieces:
# u-boot.bin, the kernel, and a root filesystem image.
#
# Layout (matches include/configs/griffin.h's bootcmd and the kernel's
# root=/dev/cf2 bootarg -- keep both in sync with any layout change here):
#   partition 1: FAT16, sector 2048,  24 MiB -- u-boot.bin, vmlinux (u-boot's
#                own fatload can't read compressed/sparse images, so these are
#                copied as plain files, not embedded as a filesystem image)
#   partition 2: raw,   sector 51200, 15 MiB -- root filesystem image, written
#                verbatim at its byte offset (erofs, ext2, whatever fits)
#
# If no ROOTFS_IMAGE is given, builds a minimal placeholder erofs (just enough
# to prove the kernel can mount root; M8's userspace replaces this).
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-${TOP}/cf.img}"
UBOOT_BIN="${UBOOT_BIN:-${TOP}/u-boot/u-boot.bin}"
KERNEL="${KERNEL:-${TOP}/linux/vmlinux.stripped}"
ROOTFS_IMAGE="${ROOTFS_IMAGE:-}"

TOTAL_MB=40
BOOT_START_SECTOR=2048
BOOT_SIZE_SECTORS=49152    # 24 MiB
ROOT_START_SECTOR=51200
ROOT_SIZE_SECTORS=30720    # 15 MiB
SECTOR_BYTES=512

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$ROOTFS_IMAGE" ]; then
	mkdir -p "$WORK/rootskel"
	echo "Griffin placeholder root -- see M8 for real userspace." > "$WORK/rootskel/README"
	mkfs.erofs "$WORK/placeholder.erofs" "$WORK/rootskel" >/dev/null
	ROOTFS_IMAGE="$WORK/placeholder.erofs"
fi

dd if=/dev/zero of="$OUT" bs=1M count="$TOTAL_MB" status=none

cat > "$WORK/layout.sfdisk" <<EOF
label: dos
unit: sectors

start=${BOOT_START_SECTOR}, size=${BOOT_SIZE_SECTORS}, type=e
start=${ROOT_START_SECTOR}, size=${ROOT_SIZE_SECTORS}, type=83
EOF
sfdisk "$OUT" < "$WORK/layout.sfdisk" >/dev/null

BOOT_SIZE_KB=$((BOOT_SIZE_SECTORS * SECTOR_BYTES / 1024))
mkfs.fat -F 16 -n GRIFFIN --offset="$BOOT_START_SECTOR" "$OUT" "$BOOT_SIZE_KB" >/dev/null

BOOT_OFFSET_BYTES=$((BOOT_START_SECTOR * SECTOR_BYTES))
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${OUT}@@${BOOT_OFFSET_BYTES}" "$UBOOT_BIN" ::U-BOOT.BIN
MTOOLS_SKIP_CHECK=1 mcopy -o -i "${OUT}@@${BOOT_OFFSET_BYTES}" "$KERNEL" ::vmlinux

ROOTFS_SIZE_BYTES=$(stat -c%s "$ROOTFS_IMAGE")
ROOT_PART_BYTES=$((ROOT_SIZE_SECTORS * SECTOR_BYTES))
if [ "$ROOTFS_SIZE_BYTES" -gt "$ROOT_PART_BYTES" ]; then
	echo "buildcfimage: rootfs image ($ROOTFS_SIZE_BYTES bytes) is larger than" \
	     "the root partition ($ROOT_PART_BYTES bytes) -- grow ROOT_SIZE_SECTORS" >&2
	exit 1
fi
dd if="$ROOTFS_IMAGE" of="$OUT" bs="$SECTOR_BYTES" seek="$ROOT_START_SECTOR" conv=notrunc status=none

echo "cf image: $OUT"
