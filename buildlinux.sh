#!/bin/sh
# Build the Griffin Linux kernel (nommu, m68k) against the forked linux tree.
#
# Produces vmlinux and a compressed vmlinux.lz4 for u-boot to load.  The kernel
# config is arch/m68k/configs/griffin_defconfig (added in M2); edit it with
# ./configlinux.sh.
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
CROSS_COMPILE="${CROSS_COMPILE:-$(realpath "${TOP}/buildroot/output/host/bin/")/m68k-linux-}"
DEFCONFIG="${DEFCONFIG:-griffin_defconfig}"
JOBS="${JOBS:-$(nproc)}"

MAKE="make -C ${TOP}/linux ARCH=m68k CROSS_COMPILE=${CROSS_COMPILE}"

${MAKE} "${DEFCONFIG}"
${MAKE} -j"${JOBS}" vmlinux

# m68k has no in-tree dts build; the DTB is external (u-boot loads it and passes
# its address in d7).  Compile dts/griffin.dts with the kernel's own dtc.
DTC="${TOP}/linux/scripts/dtc/dtc"
[ -x "${DTC}" ] || DTC="$(command -v dtc)"
"${DTC}" -I dts -O dtb -o "${TOP}/griffin.dtb" "${TOP}/dts/griffin.dts"

"${CROSS_COMPILE}strip" -o "${TOP}/linux/vmlinux.stripped" "${TOP}/linux/vmlinux"
lz4 -f -B65536 --best "${TOP}/linux/vmlinux.stripped" "${TOP}/linux/vmlinux.lz4"

echo "kernel:  ${TOP}/linux/vmlinux (+ vmlinux.lz4)"
echo "dtb:     ${TOP}/griffin.dtb"
