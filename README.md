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

## Bring-up on the emulator

The full plan lives in the approved plan file; milestones M1–M9 each have an
emulator-driven acceptance test. Run headless and capture the DUART console:

```sh
printf 'version\r' | griffin/emulator/emulator/build/emulator \
    --headless --console-stdio --no-throttle --run-cycles 100000000 u-boot.bin
```
