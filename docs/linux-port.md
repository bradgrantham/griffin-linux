# Griffin Linux port — approach as built

What the port actually looks like after implementation, where that differs
from the original proposal (`griffin/linux-port-design.txt`), and why.
Chronological findings/debugging detail lives in
[boot-handoff-notes.md](boot-handoff-notes.md); this file is the current
design of record.

## Boot chain

```
Griffin ROM monitor        (first stage; loads flat binaries from CF FAT)
  └─ run U-BOOT.BIN        u-boot, TEXT_BASE 0x1000, relocates itself to top
      └─ bootcmd:          fatload ide 0:1 0x180000 vmlinux; bootelf -p ...
          └─ kernel        stripped ELF linked at 0, entry 0x400,
                           DTB address handed over in register d7
```

Deltas from the proposal:

- **Kernel image is a stripped ELF via `bootelf`, not vmlinux.lz4/uImage via
  `bootm`.** LinuxMD's u-boot disables `CMD_BOOTM` entirely; its m68k
  `bootelf_exec` is where the d7 DTB handoff lives. lz4 decompression is
  available (`CMD_UNLZ4`) but unused so far — the 1.25 MB ELF loads from CF in
  milliseconds on the emulator.
- **The DTB is u-boot's own embedded control DT (`OF_EMBED`), not a file
  loaded from FAT.** `bootelf` copies `gd->fdt_blob` and passes that copy in
  d7. Therefore **the authoritative griffin.dts lives in the u-boot tree**
  (`u-boot/arch/m68k/dts/griffin.dts`); the superproject's `dts/griffin.dts`
  is a hand-synced reference copy only. One DT serves both u-boot's driver
  model and the kernel.
- **u-boot is fully self-contained** (own DUART serial, DM timer, CF block
  driver) rather than calling ROM routines via TRAP #15. The kernel owns all
  8 MB; nothing of the firmware stays resident. u-boot masks all interrupts
  (SR=0x2700) for its entire run and quiesces the ROM's still-running
  ENGINE/VIDEO DMA at its earliest board hook.
- **VBR discipline (68010):** u-boot relocates its vector table into its own
  high-RAM image via `movec` so the kernel's load at address 0 can't clobber
  live vectors; the kernel's `mc68010_intc_of_init()` then points VBR at its
  own `_ramvec` (upstream never did — it assumed VBR was still 0).

## Toolchains (two, on purpose)

| toolchain | tuple | libc | used for |
|---|---|---|---|
| `buildroot/output/host/bin/m68k-linux-*` | m68k-buildroot-linux-**musl** | musl | kernel, u-boot |
| `build/buildroot-userspace/host/bin/m68k-buildroot-uclinux-uclibc-*` | m68k-buildroot-**uclinux**-uclibc | uClibc-ng | userspace (bFLT) |

The proposal assumed one uClibc-ng toolchain; LinuxMD's actual toolchain
defconfig is **musl** (fine for the kernel, and their smolutils userspace
sidesteps libc entirely via the kernel's nolibc). musl has never supported
nommu — its crt assumes the ELF stack layout, so musl-linked flat binaries
fault before `main()` (and a faulting init is unkillable → silent SIGSEGV
storm). Hence the second toolchain for userspace. FDPIC was the proposal's
first choice of binary format but this gcc has no m68k FDPIC support at all;
**binfmt_flat (bFLT via elf2flt)** is the format. The `BR2_m68k_68000` CPU
variant had to be added to buildroot (stock buildroot only offers
MMU-selecting 68030/68040 and ColdFire, making `BR2_BINFMT_FLAT` unreachable
for classic m68k).

## Kernel machine + drivers

Generic DT machine (`CONFIG_M68KDT` + `CONFIG_M68KDT_GRIFFIN`), per the plan.
Compiles `-m68000`; 68010-ness is selected purely by the DT intc node
`motorola,mc68010-intc-vect`. DT `interrupts = <N>` cells are **hwirq =
autovector level − 1** (the intc domain maps level L→L−1), not the raw level.

- **`drivers/tty/serial/griffin_duart.c` — one driver for earlycon + tty
  console + the periodic clockevent.** The proposal expected to adapt an
  existing 68681 driver and have a separate timer driver; mainline's sccnxp
  binds via platform data (not DT), and more fundamentally the DUART's IMR is
  write-only with no readback, so tty and timer halves cannot live in
  independently-probed drivers without clobbering each other's mask bits.
  Clockevent registers early (`TIMER_OF_DECLARE`, owns ioremap + the one
  `request_irq` + the IMR shadow); the tty half probes late as a platform
  driver and reuses all of it. Timer mode is periodic-only (the C/T
  free-runs; STOPCC only acks), 100 Hz exact from 3.6864 MHz (preload 18432).
- **`drivers/block/griffin_cf.c`** — blk_mq polled PIO driver, disk name
  `cf` (partitions `cf1`/`cf2`, `root=/dev/cf2`), third independent port of
  the firmware's 8-bit True IDE protocol. The proposal's hope of reusing the
  pata/legacy IDE layer died on the same fact in both u-boot and the kernel:
  stock IDE code assumes 16-bit data transfers; Griffin's CF is 8-bit-only.
- **`drivers/video/fbdev/griffin_video.c`** — currently a vsync-**ack** stub
  so enabling interrupts doesn't livelock (VIDEO's vsync latch originally had
  no mask; `CTRL.IRQENB` was added to the CPLD/griffin.yml because of this
  port — the latch itself still sets every frame, IRQENB only gates the pin).
  M9 grows this into the real fbdev driver.

## Storage layout / build

`buildcfimage.sh` (a fifth build script beyond the proposal's four) makes the
bootable image: MBR; partition 1 FAT16 24 MiB at sector 2048 (`U-BOOT.BIN`,
`vmlinux`); partition 2 root filesystem at sector 51200 (erofs primary, per
the plan). `buildrootfs.sh` builds userspace: **busybox** (pinned tarball in
`dl/`, minimal applet fragment `configs/busybox-griffin.fragment`, static
uClibc-ng bFLT) with `ROOTFS_FLAVOR=smolutils` as the LinuxMD-proven
fallback.

## Emulation / debugging

All bring-up runs on the existing Moira-based emulator (now modeling a
**68010** incl. live DUART counter reads), never a QEMU fork — a gdb remote
stub in the emulator is the planned deep-debug path instead. Unattended runs
use the ROM+CF harness (`--console-in/-out`, `--run-cycles`, `--cf`); u-boot
is driven by `bootcmd`, not typed input (the ROM's RX IRQ drains scripted
console input before u-boot starts). Unmapped accesses abort with a full CPU
dump (`dump_cpu_state()`); `GRIFFIN_DUMP_ON_EXIT=1` dumps state at exit.

## Milestone status

| # | milestone | status |
|---|---|---|
| M1 | superproject + toolchain | done |
| M2 | griffin.dts + DT machine | done |
| M3 | u-boot on DUART serial | done |
| M4 | kernel first instruction + earlycon | done |
| M5 | start_kernel + full tty driver | done (tty merged into griffin_duart.c) |
| M6 | timer clockevent | done |
| M7 | CF block + erofs root mount | done |
| M8 | userspace init + shell | done (busybox/hush on uClibc-ng bFLT) |
| M9 | fbdev console | pending (ack-stub in place) |
| — | u-boot fbcon + PS/2 (standalone boot) | deferred, tracked |
