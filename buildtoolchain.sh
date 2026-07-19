#!/bin/sh
# Build the m68k-linux uClibc-ng cross toolchain via buildroot.
#
# Buildroot is used ONLY to produce the toolchain (Palmer's "least painful way
# to get an m68k toolchain that emits usable 68000-class binaries") -- NOT to
# build the kernel or rootfs, which have their own scripts against the forked
# trees.  Output lands in buildroot/output/host/bin/m68k-linux-* and is consumed
# by builduboot.sh / buildlinux.sh / buildrootfs.sh via CROSS_COMPILE.
#
# The default buildroot defconfig is LinuxMD's toolchain config; its target
# (m68k, 68000-class, uClibc-ng) is exactly what Griffin needs.  Override with
# BR_DEFCONFIG=<name> if a griffin-specific one is added later.
set -eu

BR_DEFCONFIG="${BR_DEFCONFIG:-linuxmdtc_defconfig}"
JOBS="${JOBS:-$(nproc)}"

cd "$(dirname "$0")/buildroot"

make "${BR_DEFCONFIG}"
make toolchain -j"${JOBS}"

echo "toolchain: $(realpath output/host/bin)/m68k-linux-*"
