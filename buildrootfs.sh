#!/bin/sh
# Build the Griffin root filesystem image.
#
# Primary path mirrors LinuxMD: smolutils (a purpose-built minimal init/getty/
# shell/coreutils) compiled against the kernel's nolibc, packed into an erofs
# image (read-only, compressed, RAM-frugal).  tarwak is smolutils' build helper.
#
# NOTE (per plan M8): busybox is the preferred first userspace to evaluate; this
# smolutils path is the fallback if the 8 MB budget forces it.  Kept here so the
# "clone one repo, run four scripts" property holds out of the box.
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
CROSS_COMPILE="${CROSS_COMPILE:-$(realpath "${TOP}/buildroot/output/host/bin/")/m68k-linux-}"
NOLIBCDIR="${NOLIBCDIR:-${TOP}/linux/tools/include/nolibc}"

# tarwak (meson host tool used by the smolutils packer)
( cd "${TOP}/tarwak" && meson setup --wipe build 2>/dev/null || meson setup build; meson compile -C build )
TARWAK="${TOP}/tarwak/build/tarwak"

SMOL="make -C ${TOP}/smolutils -f Makefile.68000 \
	NOLIBCDIR=${NOLIBCDIR} CROSS_COMPILE=${CROSS_COMPILE} TARWAK=${TARWAK}"

${SMOL} clean
${SMOL} DISABLE_FEATURE=net m68k.erofs

echo "rootfs:  ${TOP}/smolutils/m68k.erofs"
