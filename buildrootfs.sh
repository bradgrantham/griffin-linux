#!/bin/sh
# Build the Griffin root filesystem image (erofs).
#
# Default flavor: busybox (static uClibc-ng bFLT, built with the m68k-uclinux
# userspace toolchain -- see configs/griffin_userspace_br_defconfig; the
# kernel's musl toolchain cannot produce working flat userspace, see README
# "Building userspace binaries").  ROOTFS_FLAVOR=smolutils selects LinuxMD's
# nolibc-based minimal userspace instead (built by its own Makefile.68000
# against the KERNEL toolchain + tarwak).
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
FLAVOR="${ROOTFS_FLAVOR:-busybox}"
OUT="${OUT:-${TOP}/rootfs.erofs}"

BUSYBOX_VERSION=1.38.0
BUSYBOX_SHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2

build_busybox_rootfs() {
	# Userspace toolchain (uclinux/uClibc-ng/flat), built once with:
	#   make -C buildroot O=$PWD/build/buildroot-userspace \
	#        BR2_DEFCONFIG=$PWD/configs/griffin_userspace_br_defconfig defconfig
	#   make -C buildroot O=$PWD/build/buildroot-userspace toolchain
	UCROSS="${UCROSS:-${TOP}/build/buildroot-userspace/host/bin/m68k-buildroot-uclinux-uclibc-}"
	if [ ! -x "${UCROSS}gcc" ]; then
		echo "buildrootfs: userspace toolchain not found at ${UCROSS}gcc" >&2
		echo "buildrootfs: build it first (see configs/griffin_userspace_br_defconfig)" >&2
		exit 1
	fi

	# Fetch + verify + extract busybox (pinned release tarball, cached in dl/).
	mkdir -p "${TOP}/dl" "${TOP}/build"
	TARBALL="${TOP}/dl/busybox-${BUSYBOX_VERSION}.tar.bz2"
	if [ ! -f "$TARBALL" ]; then
		wget -O "$TARBALL" "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
	fi
	echo "${BUSYBOX_SHA256}  ${TARBALL}" | sha256sum -c - >/dev/null
	BB="${TOP}/build/busybox-${BUSYBOX_VERSION}"
	[ -d "$BB" ] || tar xjf "$TARBALL" -C "${TOP}/build"

	# Configure: allnoconfig, then merge the Griffin fragment textually and
	# let oldconfig resolve dependencies.  busybox's ancient kconfig cannot
	# do this with KCONFIG_ALLCONFIG -- its `conf -n` treats the file's
	# values as mere defaults and then answers "n" to everything anyway
	# (only `choice` selections like SH_IS_HUSH survive), silently dropping
	# every =y.  oldconfig, by contrast, respects existing .config lines as
	# user-set and only asks about newly-visible dependent options.
	make -C "$BB" allnoconfig CROSS_COMPILE="$UCROSS" >/dev/null
	grep -E '^CONFIG_' "${TOP}/configs/busybox-griffin.fragment" | while read -r line; do
		sym="${line%%=*}"
		sed -i "/^${sym}=/d; /^# ${sym} is not set/d" "$BB/.config"
		echo "$line" >> "$BB/.config"
	done
	yes "" | make -C "$BB" oldconfig CROSS_COMPILE="$UCROSS" >/dev/null
	for sym in CONFIG_HUSH CONFIG_INIT CONFIG_LS CONFIG_UNAME CONFIG_STATIC; do
		grep -q "^${sym}=y" "$BB/.config" || {
			echo "buildrootfs: $sym did not survive busybox oldconfig" >&2; exit 1; }
	done

	# FLTFLAGS reaches the elf2flt linker wrapper: -r loads text to RAM
	# (no XIP from erofs), -s sets the flat-header stack size -- the shell
	# needs far more than the 4 KB default.
	FLTFLAGS="-r -s 65536" make -C "$BB" -j"$(nproc)" \
		CROSS_COMPILE="$UCROSS" SKIP_STRIP=y busybox
	"${UCROSS}flthdr" -p "$BB/busybox"

	# Root filesystem skeleton.
	SKEL="${TOP}/build/rootskel"
	rm -rf "$SKEL"
	mkdir -p "$SKEL/bin" "$SKEL/sbin" "$SKEL/dev" "$SKEL/proc" "$SKEL/sys" \
	         "$SKEL/etc/init.d" "$SKEL/tmp" "$SKEL/root"
	# busybox's own install target populates bin/sbin with one symlink per
	# enabled applet (no target binary execution involved).
	make -C "$BB" CROSS_COMPILE="$UCROSS" SKIP_STRIP=y \
		CONFIG_PREFIX="$SKEL" install >/dev/null
	ln -sf busybox "$SKEL/bin/sh"

	cat > "$SKEL/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS
# Serial console (DUART channel A) -- the interactive shell.
ttyS0::askfirst:-/bin/sh
# Framebuffer console (tty1, rendered by fbcon on the 640x480 display) -- a
# second shell.  Input awaits a keyboard driver (PS/2, tracked), but the
# prompt renders on the display, exercising the fbdev console end to end.
tty1::askfirst:-/bin/sh
::restart:/sbin/init
EOF
	cat > "$SKEL/etc/init.d/rcS" <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
echo "Griffin: userspace up." > /dev/tty1
echo "Griffin Linux -- framebuffer console (input pending PS/2 keyboard)." > /dev/tty1
echo "Griffin: userspace up."
EOF
	chmod 755 "$SKEL/etc/init.d/rcS"

	mkfs.erofs "$OUT" "$SKEL"
}

build_smolutils_rootfs() {
	CROSS_COMPILE="${CROSS_COMPILE:-$(realpath "${TOP}/buildroot/output/host/bin/")/m68k-linux-}"
	NOLIBCDIR="${NOLIBCDIR:-${TOP}/linux/tools/include/nolibc}"

	# tarwak (meson host tool used by the smolutils packer)
	( cd "${TOP}/tarwak" && meson setup --wipe build 2>/dev/null || meson setup build; meson compile -C build )
	TARWAK="${TOP}/tarwak/build/tarwak"

	make -C "${TOP}/smolutils" -f Makefile.68000 \
		NOLIBCDIR="${NOLIBCDIR}" CROSS_COMPILE="${CROSS_COMPILE}" TARWAK="${TARWAK}" clean
	make -C "${TOP}/smolutils" -f Makefile.68000 \
		NOLIBCDIR="${NOLIBCDIR}" CROSS_COMPILE="${CROSS_COMPILE}" TARWAK="${TARWAK}" \
		DISABLE_FEATURE=net m68k.erofs
	cp "${TOP}/smolutils/m68k.erofs" "$OUT"
}

case "$FLAVOR" in
busybox)   build_busybox_rootfs ;;
smolutils) build_smolutils_rootfs ;;
*) echo "buildrootfs: unknown ROOTFS_FLAVOR '$FLAVOR'" >&2; exit 1 ;;
esac

echo "rootfs:  $OUT"
