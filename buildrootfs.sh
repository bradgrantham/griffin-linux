#!/bin/sh
# Build the Griffin root filesystem image.
#
# Default flavor: busybox (static uClibc-ng bFLT, built with the m68k-uclinux
# userspace toolchain -- see configs/griffin_userspace_br_defconfig; the
# kernel's musl toolchain cannot produce working flat userspace, see README
# "Building userspace binaries") on a WRITABLE ext2 image (issue #3): no
# journal, built unprivileged with fakeroot + mke2fs -d so files land owned
# by root.  ROOTFS_FLAVOR=smolutils selects LinuxMD's nolibc-based minimal
# userspace on erofs instead (built by its own Makefile.68000 against the
# KERNEL toolchain + tarwak).
set -eu

TOP="$(cd "$(dirname "$0")" && pwd)"
FLAVOR="${ROOTFS_FLAVOR:-busybox}"
OUT="${OUT:-}"

# Must match buildcfimage.sh's root partition (sector 51200, 30720 sectors).
EXT2_BLOCKS_1K=15360	# 15 MiB

BUSYBOX_VERSION=1.38.0
BUSYBOX_SHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2

PPPD_VERSION=2.4.9
PPPD_SHA256=f938b35eccde533ea800b15a7445b2f1137da7f88e32a16898d02dee8adc058d

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
	# Explicit stack size (the wrapper ignores FLTFLAGS -s): 16 KB has
	# carried hush + every applet since M8, and a larger stack would push
	# the image total past the order-7 (512 KB) exec-allocation line.
	"${UCROSS}flthdr" -s 16384 "$BB/busybox"
	"${UCROSS}flthdr" -p "$BB/busybox"

	# Second busybox: networking + logging applets (busybox-net).  Kept as
	# a separate binary so neither static image crosses 512 KB -- nommu
	# exec needs the whole image in ONE contiguous allocation, and >512 KB
	# means order-8 (1 MB) buddy blocks this machine effectively never has.
	BBN="${TOP}/build/busybox-net-${BUSYBOX_VERSION}"
	if [ ! -d "$BBN" ]; then
		mkdir -p "$BBN.x"
		tar xjf "$TARBALL" -C "$BBN.x"
		mv "$BBN.x/busybox-${BUSYBOX_VERSION}" "$BBN"
		rmdir "$BBN.x"
	fi
	make -C "$BBN" allnoconfig CROSS_COMPILE="$UCROSS" >/dev/null
	grep -E '^CONFIG_' "${TOP}/configs/busybox-net-griffin.fragment" | while read -r line; do
		sym="${line%%=*}"
		sed -i "/^${sym}=/d; /^# ${sym} is not set/d" "$BBN/.config"
		echo "$line" >> "$BBN/.config"
	done
	yes "" | make -C "$BBN" oldconfig CROSS_COMPILE="$UCROSS" >/dev/null
	for sym in CONFIG_PING CONFIG_TELNETD CONFIG_WGET CONFIG_SYSLOGD; do
		grep -q "^${sym}=y" "$BBN/.config" || {
			echo "buildrootfs: $sym did not survive busybox-net oldconfig" >&2; exit 1; }
	done
	FLTFLAGS="-r -s 32768" make -C "$BBN" -j"$(nproc)" \
		CROSS_COMPILE="$UCROSS" SKIP_STRIP=y busybox busybox.links
	"${UCROSS}flthdr" -s 8192 "$BBN/busybox"
	"${UCROSS}flthdr" -p "$BBN/busybox"

	# pppd 2.4.9 (matches the host's pppd; historically solid on uClinux).
	# Built with every optional feature off; -Dfork=vfork is the classic
	# uClinux port hack -- with `nodetach` and no connect/ip-up scripts the
	# fork paths are never taken at runtime, and under vfork the fd table
	# is NOT shared so the script paths would even mostly work.
	# -std=gnu89 pacifies gcc15's C23 default (2.4.9 typedefs `bool`).
	PPPTAR="${TOP}/dl/ppp-${PPPD_VERSION}.tar.gz"
	if [ ! -f "$PPPTAR" ]; then
		wget -O "$PPPTAR" "https://download.samba.org/pub/ppp/ppp-${PPPD_VERSION}.tar.gz"
	fi
	echo "${PPPD_SHA256}  ${PPPTAR}" | sha256sum -c - >/dev/null
	PPP="${TOP}/build/ppp-${PPPD_VERSION}"
	[ -d "$PPP" ] || tar xzf "$PPPTAR" -C "${TOP}/build"
	# GRIFFIN_NGROUPS: pppd declares `gid_t groups[NGROUPS_MAX]`, which with
	# uClibc's NGROUPS_MAX=65536 is 256 KB of bss -- demand-zero and
	# invisible on MMU systems, very real RAM on nommu, and enough to push
	# the flat image into order-8 (1 MB) exec allocations.  Patch the array
	# (a -D can't win: limits.h redefines NGROUPS_MAX after the cmdline).
	sed -i 's/groups\[NGROUPS_MAX\]/groups[GRIFFIN_NGROUPS]/;
	        s/getgroups(NGROUPS_MAX, groups)/getgroups(GRIFFIN_NGROUPS, groups)/' \
		"$PPP/pppd/main.c" "$PPP/pppd/pppd.h"
	grep -q GRIFFIN_NGROUPS "$PPP/pppd/pppd.h.griffin" 2>/dev/null || {
		sed -i 's|#include <limits.h>.*|&\n#define GRIFFIN_NGROUPS 32|' \
			"$PPP/pppd/pppd.h"
		touch "$PPP/pppd/pppd.h.griffin"
	}
	( cd "$PPP" && ./configure >/dev/null )
	make -C "$PPP/pppd" CC="${UCROSS}gcc" \
		COPTS="-Os -pipe -std=gnu89 -Dfork=vfork" \
		CHAPMS= MPPE= FILTER= HAVE_MULTILINK= USE_TDB= HAS_SHADOW= \
		HAVE_INET6= PLUGIN= USE_LIBUTIL= USE_EAPTLS=
	# The elf2flt wrapper ignores FLTFLAGS stack requests in this toolchain;
	# set stack sizes explicitly.  Keep every image's total (text+data+bss+
	# stack) under 512 KB = order-7, the largest allocation this machine
	# reliably has.
	"${UCROSS}flthdr" -s 32768 "$PPP/pppd/pppd"
	"${UCROSS}flthdr" -p "$PPP/pppd/pppd" >/dev/null

	# Root filesystem skeleton.
	SKEL="${TOP}/build/rootskel"
	rm -rf "$SKEL"
	mkdir -p "$SKEL/bin" "$SKEL/sbin" "$SKEL/dev" "$SKEL/proc" "$SKEL/sys" \
	         "$SKEL/etc/init.d" "$SKEL/tmp" "$SKEL/root" "$SKEL/home" \
	         "$SKEL/var/log" "$SKEL/usr/bin" "$SKEL/usr/sbin"
	# busybox's own install target populates bin/sbin with one symlink per
	# enabled applet (no target binary execution involved).
	make -C "$BB" CROSS_COMPILE="$UCROSS" SKIP_STRIP=y \
		CONFIG_PREFIX="$SKEL" install >/dev/null
	ln -sf busybox "$SKEL/bin/sh"

	# busybox-net + its applet symlinks (absolute, PATH-transparent).
	# The MAIN busybox wins every name collision: only create a net symlink
	# where nothing exists yet, so shared applets (sh, cat, the shell...)
	# stay pointed at the full binary and only genuinely net-only applets
	# (ping, telnetd, wget, syslogd...) resolve to busybox-net.
	install -m 755 "$BBN/busybox" "$SKEL/bin/busybox-net"
	while read -r link; do
		[ -e "$SKEL$link" ] && continue
		mkdir -p "$SKEL$(dirname "$link")"
		ln -sf /bin/busybox-net "$SKEL$link"
	done < "$BBN/busybox.links"

	install -m 755 "$PPP/pppd/pppd" "$SKEL/usr/sbin/pppd"
	mkdir -p "$SKEL/etc/ppp/peers"
	cat > "$SKEL/etc/ppp/options" <<'EOF'
noauth
EOF
	# `pppd call emu &` brings up the link to the emulator's host-side pppd
	# (see docs/boot-cheatsheet.md for the host command).
	cat > "$SKEL/etc/ppp/peers/emu" <<'EOF'
/dev/ttyS1
115200
nodetach
local
noauth
persist
holdoff 5
192.168.7.2:192.168.7.1
unit 0
EOF
	# udhcpc needs a script to apply leases (unused on PPP; for future NICs).
	mkdir -p "$SKEL/usr/share/udhcpc"
	cat > "$SKEL/usr/share/udhcpc/default.script" <<'EOF'
#!/bin/sh
[ "$1" = bound ] || [ "$1" = renew ] || exit 0
ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
[ -n "$router" ] && route add default gw "$router" dev "$interface"
EOF
	chmod 755 "$SKEL/usr/share/udhcpc/default.script"

	cat > "$SKEL/etc/inittab" <<'EOF'
::sysinit:/etc/init.d/rcS
# Shells on both consoles: serial (DUART channel A) and the display (tty1 =
# fbcon + PS/2 keyboard).  askfirst (respawn-equivalent on nommu), not
# getty/login: init-spawned getty and login both stall ~60 s before their
# first prompt on this setup (tty-attached init children only; see the
# boot-handoff notes and the tracked issue) while direct shells start
# instantly.  login/getty/passwd/su are built and work fine from a running
# shell.  The '-' marks a login shell, so hush sources /etc/profile
# (PS1, PATH, motd).
ttyS0::askfirst:-/bin/sh
tty1::askfirst:-/bin/sh
# Foreground (-n) under respawn: no daemonize, so no nommu re-exec hazards.
::respawn:/sbin/syslogd -n
::respawn:/sbin/klogd -n
::restart:/sbin/init
::shutdown:/bin/umount -a -r
EOF
	cat > "$SKEL/etc/init.d/rcS" <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
hostname griffin
# Credit the persisted RNG seed: without it, getty/login block in
# getrandom() for the ~2.5 minutes the crng needs to self-initialize.
seedrng
# PPP is NOT started here on purpose: on 8 MB, pppd and busybox are each
# order-7 (512 KB-contiguous) execs and only one such block survives boot
# fragmentation, so auto-starting pppd would starve the shell.  Bring the
# link up by hand when you want networking:  pppd call emu   (peer config
# in /etc/ppp/peers/emu).  XIP (execute-in-place from ROM) removes the
# either/or; revisit auto-start then.
EOF
	chmod 755 "$SKEL/etc/init.d/rcS"

	# Pre-baked creditable seed so the very first boot has a ready crng;
	# seedrng re-saves a fresh seed (from the now-initialized pool) each
	# boot on the writable root.
	mkdir -p "$SKEL/var/lib/seedrng"
	dd if=/dev/urandom of="$SKEL/var/lib/seedrng/seed.credit" \
		bs=256 count=1 status=none
	chmod 700 "$SKEL/var/lib/seedrng"
	chmod 400 "$SKEL/var/lib/seedrng/seed.credit"

	# Accounts: root, no password until `passwd` sets one (no shadow).
	cat > "$SKEL/etc/passwd" <<'EOF'
root::0:0:root:/root:/bin/sh
EOF
	cat > "$SKEL/etc/group" <<'EOF'
root:x:0:
EOF
	cat > "$SKEL/etc/hostname" <<'EOF'
griffin
EOF
	cat > "$SKEL/etc/profile" <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
export PS1='\u@\h:\w\$ '
export HISTFILE=$HOME/.hush_history
[ -f /etc/motd ] && cat /etc/motd
EOF
	cat > "$SKEL/etc/motd" <<'EOF'

  griffin -- 68010 @ 14 MHz, 8 MB, homebrew.  Linux/nommu.
  Display + PS/2 on tty1, DUART serial on ttyS0.

EOF

	# ext2 (writable root), sized to the CF root partition; fakeroot makes
	# the tree root-owned without host privileges.
	rm -f "$OUT"
	fakeroot -- sh -c "chown -R 0:0 '$SKEL' && \
		mke2fs -q -F -t ext2 -b 1024 -I 128 -L griffin \
			-d '$SKEL' '$OUT' $EXT2_BLOCKS_1K"
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
busybox)   : "${OUT:=${TOP}/rootfs.ext2}";  build_busybox_rootfs ;;
smolutils) : "${OUT:=${TOP}/rootfs.erofs}"; build_smolutils_rootfs ;;
*) echo "buildrootfs: unknown ROOTFS_FLAVOR '$FLAVOR'" >&2; exit 1 ;;
esac

echo "rootfs:  $OUT"
