#!/bin/sh
# Edit the Griffin kernel config interactively and save it back to
# arch/m68k/configs/griffin_defconfig.  Run menuconfig, then savedefconfig.
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
CROSS_COMPILE="${CROSS_COMPILE:-$(realpath "${TOP}/buildroot/output/host/bin/")/m68k-linux-}"

MAKE="make -C ${TOP}/linux ARCH=m68k CROSS_COMPILE=${CROSS_COMPILE}"

${MAKE} griffin_defconfig
${MAKE} menuconfig
${MAKE} savedefconfig
mv "${TOP}/linux/defconfig" "${TOP}/linux/arch/m68k/configs/griffin_defconfig"

echo "saved: linux/arch/m68k/configs/griffin_defconfig"
