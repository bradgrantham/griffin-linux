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
      └─ bootcmd:          fatload ide 0:1 0x400000 vmlinux; bootelf -p ...
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

## Binary format assessment: bFLT vs FDPIC vs static-PIE

Three nommu userspace formats, evaluated 2026-07 (details in the M8 notes):

- **bFLT (current):** smallest images, kernel-relocated, proven. No text
  sharing between processes with `-r`/erofs (every exec is a full private
  copy) -- XIP would need a romfs-style filesystem. elf2flt tooling quirks;
  gdb-hostile.
- **True ELF FDPIC:** would add cross-process text sharing (the big win at
  8 MB), shared libs, standard tooling -- at the cost of descriptor-based
  calls (~5-15% code growth + indirection on a 14 MHz CPU). **Does not exist
  for m68k**: GCC's FDPIC backends are arm/bfin/frv/sh only; no m68k psABI
  has ever been defined. Getting there means authoring the ABI + gcc +
  binutils + libc + gdb work. The kernel is the one finished piece
  (arch/m68k has ELF_FDPIC_PLAT_INIT -- Ungerer's loader glue).
- **Static-PIE ELF via binfmt_elf_fdpic (LinuxMD's actual format):**
  smolutils links `-fpie -pie -Wl,--no-dynamic-linker`; the FDPIC loader
  maps it and provides a proper **ELF** stack layout at entry -- which would
  even sidestep the musl-crt incompatibility that forced the second
  toolchain. No compiler FDPIC needed, gdb-friendly; but no text sharing
  (memory behavior = bFLT) and fatter images. Candidate experiment if we
  ever want to retire the uClibc-ng toolchain or debug userspace in gdb.

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
dump (`dump_cpu_state()`); `GRIFFIN_DUMP_ON_EXIT=1` dumps state at exit and
`GRIFFIN_DUMP_RAM=addr:len` dumps a RAM range (ASCII) at exit.

**Video-DMA stall model.** The ENGINE's per-scanline burst cost
(`EngineState::SYSCLKS_PER_LINE`) is charged to the CPU clock **smoothly** by
default — accrued as a debt and paid a few cycles per CPU step — mirroring how
real DMA steals the bus at bus-cycle granularity via BR/BG/DTACK. The older
"lump" model (`GRIFFIN_DMA_STALL_LUMP`) injects the whole burst as one `sync()`
between two whole instructions; that unphysical discontinuity wedged the M9
fbcon boot (see DMA-stall note under follow-ups). `GRIFFIN_DMA_STALL_STEP`
tunes the smooth pay-down rate; `GRIFFIN_NO_DMA_STALL` disables the stall
entirely. The stall cost itself (2 sysclks/word + per-burst arbitration) is
independent of the delivery model.

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
| M9 | fbdev console | done (fbcon boots to shell with DMA live; see DMA-stall note and [the boot screenshot](m9-fbcon-boot.png)) |
| — | u-boot fbcon + PS/2 (standalone boot) | done (issue #4; see "Standalone boot" below) |

## Standalone boot (issue #4): video console + PS/2 at every stage

The machine is usable with no serial cable, power-on through a shell on the
display. The ROM monitor was already standalone (textport + PS/2 input mux in
`firmware/syscalls.c`); this work added the u-boot and kernel-input stages.
All three stages stay **self-contained** (the issue's "should firmware be
factored?" resolved as *no* — the firmware textport/ps2 code is the porting
reference, not a shared library).

- **u-boot video console** (`u-boot/drivers/video/griffin_video.c`,
  `CONFIG_VIDEO_GRIFFIN`): u-boot's generic console renderer rejects 1bpp, so
  this is a custom `vidconsole_ops` driver (byte-per-glyph-row 8x16, one
  contiguous memmove per scroll, header-skipping row clear) on a
  `UCLASS_VIDEO` driver that owns the fixed 0x7f0000 carveout (`plat->base`
  set at **bind** time skips uclass fb allocation) with `line_length = 84`.
  The uclass's `video_clear()` wipes the in-band palette headers; the
  `video_sync` op restamps them behind a sentinel check. Two fork quirks:
  `fonts[0]` is unconditionally the 8x8 font (the driver re-selects "8x16" at
  probe), and `CONFIG_VIDEO_ANSI` is required or `\e[2K` prints literally.
- **ram_top fix (pre-existing bug):** relocated u-boot's bss ran to ~0x7ff088,
  *inside* the framebuffer carveout. `board_get_usable_ram_top()` now caps
  usable RAM at 0x7f0000.
- **Live handoff:** u-boot no longer disables ENGINE/VIDEO before bootelf
  (the old `last_stage_init` disable predates the fixed carveout); the last
  u-boot screen persists until the kernel's fbdev quiesces-then-reinits at
  probe. u-boot never sets VIDEO IRQENB, so the free-running vsync latch
  stays gated. (u-boot confirmed at SR=0x2700 throughout — checked with a
  mid-countdown CPU dump — so the ROM's still-installed ISRs never run.)
- **u-boot keyboard** (`u-boot/drivers/input/griffin_kbd.c`,
  `CONFIG_GRIFFIN_KEYBOARD`): polled `UCLASS_KEYBOARD` driver on the GLUE
  PS/2 frame engine (`griffin,glue`, now status "okay"), feeding u-boot's
  set-1-indexed input tables through a set2→set1 map. Host TX (CTRL
  CLK-inhibit >= 100 us, parity in TX_DATA address bit 1) sends 0xF4 at
  start and re-sends it whenever the keyboard announces BAT (0xAA) — the
  repeated-BAT recovery for a never-configured keyboard. `BOOTDELAY=2`
  (the default) gives an autoboot-abort window; `stdin=serial,kbd`,
  `stdout/stderr=serial,vidconsole` via `CONSOLE_MUX`.
- **Kernel early framebuffer console:** a CON_BOOT console in
  `griffin_video.c` (registered from a `console_initcall`, micro-textport
  rendering with the built-in VGA8x16 font) puts the kernel log on the
  display from early init — closing the dark window between u-boot's last
  frame and fbcon.  CON_PRINTBUFFER replays everything printed before
  registration; the fbdev probe silences it when fbcon takes the buffer.
  Notes: the earlycon framework holds only ONE early console (the DUART has
  it; a second `earlycon=` gets -EALREADY), and with `console=` entries on
  the cmdline an unmatched extra console must be pre-enabled (CON_ENABLED —
  the netconsole pattern) or `register_console` ignores it.
- **Kernel keyboard** (`linux/drivers/input/serio/griffin_ps2.c`,
  `CONFIG_SERIO_GRIFFIN` + atkbd): minimal serio port — ISR reads the byte,
  flags frame/parity errors, `serio_interrupt()`, then W1C-acks (the same
  no-self-mask latch discipline as the vsync). `serio->write` is real
  (firmware ps2.cpp TX recipe), so atkbd runs its full GETID probe and
  handles a mid-session BAT via reconnect. The tty1 fbcon shell is now
  interactive.
- **Emulator test surface:** `--ps2-in FILE` injects scripted keystrokes
  (`delay MS` / `text STRING` / `raw HH..`), and the PS/2 device model
  answers host commands (0xFF→FA+BAT, 0xF2→FA AB 83, LEDs/typematic/enable)
  so full keyboard init works unattended. Verified end-to-end: ROM monitor
  driven by keyboard, u-boot autoboot aborted + `version` typed standalone,
  kernel `uname -a` typed into the fbcon shell, and stray-BAT recovery.

## Tracked follow-ups (post-M9)

- **PPP over DUART channel B.** The XR68C681's channel B is currently unused
  (only channel A = console/timer is driven). Goal: run pppd over /dev/ttyS1
  for IP networking. Needs: extend griffin_duart.c to register channel B as a
  second uart_port (ttyS1) sharing the same chip/IRQ/IMR-shadow (RXRDYB/TXRDYB
  bits, MR1B/CSRB/CRB/RBB/TBB registers -- already in griffin.yml), then
  CONFIG_PPP + a userspace pppd (uClibc-ng bFLT). The one-driver-owns-the-chip
  structure already in place makes ch B a natural addition.
- **ext2/3/4 writable root.** erofs (current root) is read-only. The CF block
  driver already does writes, so a writable root just needs the fs: ext2 is
  the low-overhead choice for 8 MB (no journal); build unprivileged with
  `mke2fs -d rootskel` (or a small ext4 with `-O ^has_journal`). Kept erofs as
  default for now (RAM-frugal, compressed); ext2 is a buildrootfs.sh flavor
  away. (Analysis: plenty of CF room and RAM headroom vs. the Megadrive port,
  so ext2/4 is entirely viable; journaling just isn't worth the writes/RAM.)
- **fbcon DMA-stall boot wedge — RESOLVED (emulator model).** M9's fbcon boot
  intermittently wedged right after "crng init done", nondeterministically, only
  once the fbdev driver enabled ENGINE DMA. Ruled out (with evidence): frozen
  ticks (a normal 100 Hz tick was caught mid-`__schedule`), serial-TX starvation
  (DUART TXRDY is always ready), livelock (CPU was idle, not spinning), and
  fbcon rendering (wedges on `console=ttyS0` too). Root cause: the emulator's
  **coarse per-scanline DMA-stall lump** — a single `sync()` fast-forwarding the
  shared clock ~a dozen instructions' worth in one interrupt-blind gap, at the
  video-scanline cadence. On the nommu/UP kernel that video-phased clock
  discontinuity mis-times a scheduler wakeup: a freshly-created kthread parks in
  `kthread()`'s initial `schedule()` and never gets run, so worker creation's
  `wait_for_completion_killable` hangs and init stalls while ticks keep firing.
  Proven to be the discontinuity *magnitude*, not the total slowdown:
  distributing the identical total stall across instructions boots cleanly to a
  shell. Fix: the emulator now delivers the stall smoothly by default (real DMA
  has no such discontinuity — it steals the bus at bus-cycle granularity). No
  Griffin hardware or kernel change was needed. Full writeup in
  boot-handoff-notes.md M9.
