#!/bin/sh
# Build u-boot (second-stage bootloader) for the Griffin board.
#
# Griffin's ROM monitor loads u-boot.bin from the FAT partition as a flat binary
# and jumps to it; u-boot then provides kernel load + DTB + bootargs.  The
# griffin_defconfig / board dir are added in milestone M3.
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
CROSS_COMPILE="${CROSS_COMPILE:-$(realpath "${TOP}/buildroot/output/host/bin/")/m68k-linux-}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-griffin_defconfig}"
JOBS="${JOBS:-$(nproc)}"

make -C "${TOP}/u-boot" "${UBOOT_DEFCONFIG}"
make -C "${TOP}/u-boot" CROSS_COMPILE="${CROSS_COMPILE}" -j"${JOBS}"

echo "u-boot: ${TOP}/u-boot/u-boot.bin"
