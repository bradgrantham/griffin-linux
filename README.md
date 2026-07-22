# griffin-linux

Port of a modern nommu m68k Linux kernel to the **Griffin** homebrew 68010
computer, developed on the Moira emulator until Rev 2 PCBs arrive.

Structurally modeled on [LinuxMD](https://github.com/LinuxMD) (Daniel Palmer's
Linux-on-Sega-Mega-Drive). Griffin boots as a **Generic DT Machine**: the board
is described by `linux/arch/m68k/boot/dts/griffin.dts` and drivers bind by
`compatible` string — no hardcoded board file.

## Layout

| path          | what                                                          |
|---------------|--------------------------------------------------------------|
| `griffin/`    | existing Griffin tree — ROM firmware, Moira emulator, CPLDs, `griffin.yml` |
| `buildroot/`  | submodule — **toolchain only** (m68k-linux musl, GCC 15)     |
| `linux/`      | submodule — forked kernel tree with Griffin DT + drivers      |
| `u-boot/`     | submodule — forked u-boot with the Griffin board (2nd stage)  |
| `smolutils/`  | submodule — minimal userspace (erofs rootfs); busybox evaluated first |
| `tarwak/`     | submodule — smolutils build helper                            |

## Build (clone one repo, run the stages)

```sh
git submodule update --init --recursive
make toolchain   # buildroot -> buildroot/output/host/bin/m68k-linux-*
make uboot       # -> u-boot/u-boot.bin
make linux       # -> linux/vmlinux, vmlinux.lz4, griffin.dtb
make rootfs      # -> smolutils/m68k.erofs
make cfimage     # -> cf.img (bootable: FAT boot partition + erofs root)
# or: make all
make config      # menuconfig -> arch/m68k/configs/griffin_defconfig
```

`cfimage` defaults to a placeholder root (just enough to prove the kernel
mounts it) if `rootfs` hasn't been built yet; pass `ROOTFS_IMAGE=path` to
`buildcfimage.sh` to embed a real one.

Buildroot builds **only** the toolchain; kernel/u-boot/rootfs use dedicated
scripts against the forked trees with `CROSS_COMPILE` pointing at the buildroot
output. Host prereqs: `build-essential git wget cpio unzip rsync bc
libncurses-dev file python3 lz4 erofs-utils` (+ `meson`/`ninja` for tarwak).

## Building userspace binaries

Griffin is nommu, so userspace is **bFLT (binfmt_flat)** — no demand paging, no
fork (vfork only), every exec loads the whole binary into RAM. The kernel has
`CONFIG_BINFMT_FLAT=y`; `CONFIG_BINFMT_ELF_FDPIC` is enabled but useless here
(this gcc has no FDPIC support at all).

Producing a bFLT binary with the buildroot toolchain:

```sh
# one-time: build the elf2flt linker wrapper into the toolchain
( cd buildroot && make host-elf2flt )

# then: -Wl,-elf2flt makes the (wrapped) linker emit bFLT;
# FLTFLAGS sets the flat-header stack size (default 4 KB is far too small)
FLTFLAGS="-s 16384" \
  buildroot/output/host/bin/m68k-linux-gcc -m68000 -Os -static \
  -Wl,-elf2flt -o prog prog.c
buildroot/output/host/bin/m68k-buildroot-linux-musl-flthdr -p prog  # inspect
```

**Critical caveat: the toolchain's musl libc does not work for flat userspace.**
musl has never supported nommu — its crt expects the ELF stack layout at entry,
but binfmt_flat (`ARGVP_ENVP_ON_STACK`) passes argc/argv-pointer/envp-pointer
instead, so a musl-linked init reads garbage pointers and faults before its
first instruction of `main()` (and a faulting init is unkillable, so the
machine "hangs" in a silent SIGSEGV storm). This is exactly why LinuxMD's
smolutils links against the **kernel's nolibc** (`linux/tools/include/nolibc`)
rather than the musl in the very same toolchain. Working options for Griffin
userspace: nolibc (smolutils path, proven on this kernel), or a second
buildroot toolchain built with `BR2_BINFMT_FLAT` + uClibc-ng (the classic
uClinux userspace libc, flat-aware crt) for busybox-class programs.

The rootfs skeleton must contain `/dev` (devtmpfs mount point — without it the
kernel logs `devtmpfs: error mounting -2` and userspace has no console node),
plus `/proc`, `/sys`, and the init at `/sbin/init`.

## Bring-up on the emulator

The full plan lives in the approved plan file; milestones M1–M9 each have an
emulator-driven acceptance test. Run headless and capture the DUART console:

```sh
printf 'version\r' | griffin/emulator/emulator/build/emulator \
    --headless --console-stdio --no-throttle --run-cycles 100000000 u-boot.bin
```
