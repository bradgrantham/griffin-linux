# Griffin Linux boot-handoff notes

Findings from reading Palmer's generic-DT m68k machine in the `linux/` fork
(branch `m68kdt_linuxmd_fabledmath`, our local `griffin` branch). These pin down
the ROM → u-boot → kernel handoff for Griffin.

## Generic DT machine layout

- Core machine: `CONFIG_M68KDT` — `arch/m68k/kernel/setup_dt.c` +
  `arch/m68k/dt/head.S` (+ `arch/m68k/dt/Makefile`).
- Per-board select: `CONFIG_M68KDT_<MACHINE>` (e.g. `CONFIG_M68KDT_MEGADRIVE`).
  Griffin adds `CONFIG_M68KDT_GRIFFIN` + `griffin_defconfig`.
- `setup_dt.c` calls `setup_machine_fdt(_dtblob)` then reserves `_text.._end`
  and the FDT via memblock; `memory_start/end` come from the DT memory node.

## Kernel entry contract (`arch/m68k/dt/head.S`) — the critical part

At `_start` the kernel expects, from the bootloader:

1. **DTB address in register `d7`.** head.S does
   `lea _dtblob,%a0; movel %d7,(%a0)`. So the **device tree is loaded by u-boot
   and its address passed in `d7`** — it is *not* a builtin blob. (Settles plan
   decision #2: u-boot loads `griffin.dtb` and jumps with its address in d7.)
2. Interrupts are masked (`move.w #0x2700,%sr`) by the kernel itself.
3. head.S installs an infinite-loop `nullcatch` (`trap #1; jmp .`) at address 0
   to trap null-pointer derefs, then sets `_ramvec = CONFIG_VECTORBASE`.
   → **`CONFIG_VECTORBASE` is the 68010 VBR base** where the RAM vector table
   lives. Pick a Griffin value (low RAM, away from the kernel image).
4. Clears BSS, sets SP to `init_thread_union + THREAD_SIZE`, `jsr start_kernel`.
5. `_is68k` (word in .data) distinguishes 68000 vs 68010+ for the port.

### Early `__putch` is per-machine — Griffin's is the M4 first-instruction hook

head.S emits `L` at entry, `s` before `start_kernel`, `c` if it ever returns,
via a `__putch` macro that is **machine-specific**:
- MC68EZ328 variant pokes its on-chip UART.
- Megadrive variant pokes the EverDrive mailbox at `0xa130d0`.

Griffin needs a `__putch` that writes the XR68C681 DUART:
- poll `SRA` (0xF80003) bit 2 `TXRDY` high, then write byte to `TBA` (0xF80007).
Gate it on `CONFIG_M68KDT_GRIFFIN`. This is the "prove the first instruction
executes" deliverable for M4, independent of full earlycon.

## Serial driver: reuse `drivers/tty/serial/sccnxp.c`

Mainline **SCCNXP** driver already supports the SC28L91 / SC26xx / **68681**
family (same register model as Griffin's XR68C681). It is the adaptation target
for the M4 earlycon + M5 `ttyS0` tty driver rather than writing one from scratch.
Griffin register map (from `griffin.yml`, base 0xF80000, byte regs on odd
addresses): MR1A/MR2A 0x01, SRA 0x03 (TXRDY=bit2, RXRDY=bit0), TBA/RBA 0x07,
IMR/ISR 0x0B, counter/timer CTUR/CTLR 0x0D/0x0F, STARTCC/STOPCC 0x1D/0x1F.
DUART IRQ is autovector level 5.

## M2 outcome (built & verified)

Griffin is recognized as a generic DT machine and the kernel links clean:

- **CPU config:** nommu classic auto-selects `CONFIG_M68000` (`def_bool
  M68KCLASSIC && !MMU`, builds `-m68000`). There is **no compile-time
  CONFIG_M68010**; the 68010 behavior (correct autovector frames, `_is68k=0`) is
  chosen entirely by the DT intc `motorola,mc68010-intc-vect`. `HZ` defaults to
  100 for non-megadrive (our DUART-timer target).
- **Files added/changed in `linux/` (branch `griffin`):**
  - `arch/m68k/Kconfig.machine`: added `config M68KDT_GRIFFIN`.
  - `arch/m68k/dt/head.S`: `__putch` now `#if MEGADRIVE / #elif GRIFFIN / #else`;
    Griffin variant polls DUART `SRA` bit2 then writes `TBA` (the M4 first-instr hook).
  - `arch/m68k/68000/Makefile`: gated `everdrive.o everdrive_fifo.o` on
    `CONFIG_M68KDT_MEGADRIVE`.
  - `drivers/block/Makefile`: gated `everdrive_blk.o` on `CONFIG_M68KDT_MEGADRIVE`
    (was unconditional `obj-y`; it pulled in megadrive FIFO/VDP symbols).
  - `arch/m68k/configs/griffin_defconfig`: megadrive config minus `VDP_TTY`/
    `EVERDRIVE_TTY`, with `M68KDT_GRIFFIN=y`.
- **DTB is external**, built standalone by `buildlinux.sh` with the kernel's
  `scripts/dtc/dtc` from `dts/griffin.dts` → `griffin.dtb` (m68k has no in-tree
  `make dtbs`). u-boot will load it and pass its address in d7.
- **Result:** `vmlinux` ~1.26 MB (text 1,057,550 / data 175,408 / bss 24,973),
  `vmlinux.lz4` 723 KB, `griffin.dtb` 1662 B; decompile confirms memory@0 8 MB,
  intc onecell, and DUART/ENGINE/VIDEO/GLUE nodes at the right addrs + IRQ levels.

## M3 outcome (u-boot Griffin board builds)

u-boot builds a **116 KB `u-boot.bin`** for Griffin (`make griffin_defconfig` +
`CROSS_COMPILE` = buildroot musl toolchain). Files (u-boot `griffin` branch off
`mc68000_megadrive`):

- `drivers/serial/serial_xr68c681.c` (+ Makefile/Kconfig): DM serial, compatible
  `griffin,duart-xr68c681`, 115200 8N1 via the firmware's known-good init, plus a
  `DEBUG_UART` earlyprintk hook (`DEBUG_UART_BASE=0xf80000`).
- `board/griffin/griffin/` — `griffin.c` (8 MB dram_init; `last_stage_init`
  quiesces `ENGINE.CTRL@0xd00005` then `VIDEO.CTRL@0xe00005` before boot),
  `Kconfig`/`Makefile`/`MAINTAINERS`; `include/configs/griffin.h`.
- `arch/m68k/dts/griffin.dts` — authoritative board DT, `#include "mc68000.dtsi"`
  with intc/cpu overridden to the 68010 variant; embedded (`OF_EMBED`) and passed
  to Linux in d7.
- `arch/m68k/cpu/mc68000/start.S` — added a `CONFIG_TARGET_GRIFFIN` branch to the
  early `__putch` macro (DUART poll SRA.TXRDY → TBA) and the target hello block.
- `configs/griffin_defconfig` — serial console, `TEXT_BASE=0x1000` (Griffin ROM
  flat-load addr), 14 MHz clock, `CMD_ELF`(bootelf)+`CMD_UNLZ4`; registered
  `TARGET_GRIFFIN` in `arch/m68k/Kconfig`.

**Kernel entry contract confirmed on the u-boot side:** `arch/m68k/lib/elf.c`
does `move.l fdtaddr, %d7` before entering the kernel — u-boot's `bootelf` passes
the DTB in d7, matching `arch/m68k/dt/head.S`.

### Open: emulator execution harness for u-boot/kernel

The Moira emulator's positional arg is a **ROM image** (loaded at 0xC00000,
entered via the reset vector); it cannot directly run a RAM blob. Two ways to
exercise `u-boot.bin` (and later the kernel):
1. **Real ROM + CF image** (faithful): boot `firmware/rom.bin` with
   `--cf cf.img`, drive `run u-boot.bin` over `--console-stdio`. Needs the
   firmware ROM built + a FAT CF image tool. Reused for M7 (CF root).
2. **Add a direct-load flag to the emulator** (fast iteration): e.g.
   `--load FILE@ADDR`, `--entry ADDR`, `--set-d7 ADDR` — load u-boot/kernel/DTB
   into RAM and jump, no ROM/FAT dance. Small, matches the existing
   automation-flag philosophy, and unblocks all of M4–M9 kernel iteration.

## Working emulator test harness (reusable for M4-M9)

The Moira emulator boots a **ROM image** and enters via the reset vector, so
u-boot/kernel (RAM images) are exercised through the real firmware loader:

1. Build once: `cmake -Bbuild . && cmake --build build` in `griffin/emulator`
   (Moira submodule: `git submodule update --init` in `griffin/`; the emulator
   vendors/builds SDL3 itself).
2. Firmware ROM: the `firmware/m68k-*` wrappers call a **podman** container that
   isn't installed here; the identical native toolchain lives at
   `~/Downloads/m68k-unknown-elf/bin/`.  Build with make-var overrides (do NOT
   edit the committed wrappers):
   `make rom.bin M68K_GCC=<tb>/m68k-unknown-elf-gcc M68K_GXX=<tb>/...-g++ M68K_OBJCOPY=<tb>/...-objcopy`
   (native g++ is crosstool-NG 15.2.0, builds the c++23 firmware clean).
3. CF image (raw FAT16, FatFs auto-detects SFD): `dd` a blank file,
   `mkfs.fat -F 16`, `MTOOLS_SKIP_CHECK=1 mcopy -i cf.img u-boot.bin ::U-BOOT.BIN`.
4. Run: `printf 'run U-BOOT.BIN\r...' | griffin/emulator/build/emulator
   --headless --console-stdio --no-throttle --run-cycles N --cf cf.img
   griffin/firmware/rom.bin`.

**Verified:** ROM boots -> mounts CF -> `run U-BOOT.BIN` loads at 0x1000 -> jumps
-> start.S Griffin `gr` hello -> u-boot banner `U-Boot 2026.01 ... Model: Griffin
68010 / DRAM: 8 MiB` on the DUART.  Serial driver + board + boot chain all good.

### M3 relocation bug (FIXED): megadrive mapper poke in relocate_code

Symptom looked like a hang after "DRAM: 8 MiB"; it was actually the **emulator
aborting** (the diagnostic `printf` before `abort()` was lost to unflushed
stdout, and the shell's "Aborted" went to a different fd than the piped output).

Root cause: LinuxMD hardcoded the Mega EverDrive PSRAM-bank mapper setup into the
**shared** `arch/m68k/cpu/mc68000/lib.c:relocate_code` --
`for (i=1..7) *(u16*)0xa130f0 [i] = i` -- to map upper PSRAM before relocating
u-boot high.  Griffin's RAM is directly mapped, so those writes hit nonexistent
0xA130F2.. and the emulator's `write16` unmapped-access `abort()` fired.

Fix: guarded that loop with `#ifdef CONFIG_TARGET_MEGADRIVE`.  u-boot now
relocates (copy 0x1000 -> 0x7e0000, mon_len 0x1fbd0, jump 0x7e8ee0) and reaches
the `=>` prompt; `bootcmd=version` (bootdelay 0) executes over the DUART.

**Diagnostic aids added to the emulator** (`emulator.cpp`, kept): unmapped
read/write messages now `fprintf(stderr)+fflush` (and print the faulting `getPC()`)
so an unmapped access is visible before `abort()`; env `GRIFFIN_DUMP_ON_EXIT=1`
dumps PC/registers/disassembly at run end.  NB: an unmapped access on real
Griffin is a DTACK-timeout bus error, not a crash -- consider making the emulator
raise a 68k bus error instead of `abort()` if kernel probing needs it later.

### M3 RX bug (FIXED): firmware DUART IRQ eats u-boot keystrokes

Symptom: u-boot TX works (banner, version) but no typed command does anything at
`=>`, while the firmware monitor's input works fine on the same pty.

Root cause: the ROM's `duart_runtime_init` leaves `IMR = RXRDYA | CTR_READY`
enabled, and u-boot runs with CPU interrupts unmasked (`SR=0x2000`).  So every
keystroke (and every 100 Hz tick) raises level-5 IRQ; the CPU vectors -- via the
firmware's still-live RAM vector table at 0 -- into the firmware's DUART ISR in
ROM, which reads RBA and drains the byte before u-boot's poll loop sees RXRDY.

Fix: `serial_xr68c681` probe writes `IMR=0` (offset 0x0B) -- it's a poll-mode
driver and wants no DUART interrupts.  Confirmed by a FIFO-console repro (write
`run U-BOOT.BIN`, let u-boot boot, then write commands so only u-boot is reading):
before the fix u-boot ignored `help`/`version`; after, both execute.

## M4 outcome (kernel boots to earlycon; timer is the next blocker)

Full chain works: ROM -> u-boot (CF fatload) -> bootelf -> kernel head.S (`L`/`s`
putch markers) -> start_kernel -> **earlycon boot log** ending at
`timer_probe: no matching timers found` (M6's deliverable).  Key work:

- **u-boot Griffin CF block driver** (`drivers/block/griffin_cf.c`,
  `CONFIG_GRIFFIN_CF`): UCLASS_IDE parent bound to `griffin,cf-ide` +
  UCLASS_BLK child; 8-bit PIO read ported from firmware; IDENTIFY capacity;
  `desc->type = DEV_TYPE_HARDDISK` required or the partition layer rejects the
  device ("Bad device specification"); registers its own hook-free
  `UCLASS_DRIVER(ide)` when `CONFIG_IDE` is off.  u-boot's stock ide.c can't be
  used: it assumes 16-bit data transfers.  `fatload ide 0:0 0x180000 vmlinux`
  reads 1.2 MB fine.  NB: default parser has no `&&` -- use `;` in bootcmd.
- **u-boot timer** (`drivers/timer/griffin_duart_timer.c`,
  `CONFIG_GRIFFIN_DUART_TIMER`, DT `griffin,duart-timer`): DUART C/T as
  timebase, 0xFFFF preload, CUR/CLR read -> 64-bit up-count.  Required: u-boot
  panics with no DM timer.  The emulator previously returned 0 for CUR/CLR;
  added live-count modeling (STARTCC latches start clock; CUR latches, CLR low
  byte -- matches 68681 protocol).
- **Vectors/VBR (the big one)**: u-boot (MC68000 build) keeps its vector table
  AT 0 (`trap_init(0)`) and `setvbr` is a no-op, so bootelf loading the kernel
  at 0 would clobber live vectors.  Griffin is a 68010: `arch_initr_trap` now
  fills a table inside u-boot's relocated image and sets VBR via hand-emitted
  `movec` (`.word 0x4e7b,0x0801`, operand pinned to d0; the tree compiles
  -m68000).  Gotchas found on the way: (1) the MC68000 `int_handlers[]` only
  populates vectors 4/5/8 -- everything else must be pointed at the
  `_int_sled_32` catcher or a stray IRQ vectors through 0; (2) the ROM hands
  over with VIDEO vsync (L6) + PS/2 (L4) IRQs live, and u-boot ran at SR=0x2000
  the whole time -- Griffin start.S now sets **SR=0x2700 for u-boot's entire
  run** (u-boot polls everything); (3) ENGINE/VIDEO are quiesced in `dram_init`
  (earliest hook) incl. CLRINT ack, not just before bootm.
- **Emulator is now a 68010** (`setModel(moira::Model::M68010)` before reset).
  Moira supports it fully (movec/VBR, format-8 frames); the firmware runs
  unchanged.
- **bootelf's "ELF overwrites reserved memory 0x0..: -22" is non-fatal** -- it
  proceeds and the load at 0 is fine (u-boot vectors are VBR-high now, and
  u-boot never returns).
- **Kernel earlycon** (`drivers/tty/serial/griffin_duart.c`,
  `CONFIG_SERIAL_GRIFFIN_DUART`): `OF_EARLYCON_DECLARE(griffin_duart,
  "griffin,duart-xr68c681")`, polled TXRDY->TBA; needs `select SERIAL_CORE`
  **and `select SERIAL_CORE_CONSOLE`** (uart_console_write/uart_parse_earlycon
  are gated on the latter).  On nommu, earlycon membase = phys addr (no
  FIX_EARLYCON_MEM on m68k).  Bound via bootargs `earlycon` + DTB stdout-path.

### Harness note: scripting input to u-boot

`--console-in` is read on demand; the firmware's RX-IRQ handler drains the whole
file into its RAM queue before `run` jumps to u-boot, so bytes after the launch
command are lost.  Drive u-boot via its **`bootcmd`/env** (scripted autoboot),
not post-jump console input -- the pattern for M4+ (load + boot the kernel).

## M6 outcome (timer works; kernel boots to the expected M7 boundary)

**Deliverable:** `drivers/clocksource/timer-griffin-duart.c` (`CONFIG_GRIFFIN_DUART_TIMER`,
DT `griffin,duart-timer`, reusing the SAME node u-boot's own DM timer binds --
one canonical node, two independent driver models). Periodic-only clockevent
(`CLOCK_EVT_FEAT_PERIODIC`): the DUART C/T in Timer mode is inherently
free-running once started (STOPCC only clears IRQ status, never halts -- so
there's no real one-shot reprogram), so `set_state_periodic`/`set_state_shutdown`
just mask/unmask IMR's CTR_READY bit rather than touching the counter. Preload
= `DUART_CLOCK/(2*HZ)` = 18432 exactly for 3.6864 MHz / 100 Hz (no rounding
drift). IRQ is `IRQF_SHARED` on hwirq 4, proactively, since M5's RX-driven tty
will share the same DUART autovector line later.

**Two serious bugs found and fixed getting here** (both were "kernel silently
makes zero progress after clocksource: jiffies" -- neither was really a timer
bug at all):

### Bug 1: VIDEO's vsync IRQ has no mask -- added CTRL.IRQENB in hardware

VIDEO's vsync timing generator free-runs regardless of CTRL.ENABLE (must
already be counting before ENABLE, since output starts at the next vsync
boundary), and the only register is CLRINT (ack, no enable/disable). Once the
kernel unmasks CPU interrupts (required for the timer), the long-unacked vsync
latch (last acked once, early, by u-boot) fires immediately, and with no
VIDEO IRQ handler yet (M9 not built), the CPU livelocks: RTE drops the SR mask
below 6, the still-latched IRQ instantly retriggers, forever. Silent -- no
"nobody cared" diagnostic, since the (disabled) DT node had no handler
registered, so there's no irq_desc to warn against; PC/SP differ sample-to-
sample (visited via `GRIFFIN_DUMP_ON_EXIT`) because it's cycling through
different points in exception entry/exit, not a single-PC spin.

**Hardware fix (per user decision):** added `CTRL.IRQENB` (bit 1, default 0)
in `griffin.yml` and `cpld/video/video.v` -- gates only the `~VIDEO_IRQ` pin
(`assign nVIDEO_IRQ = ~(video_irq_latched & video_irqenb);`), matching DUART's
ISR/IMR split (latch stays unconditional so a late unmask still sees a pending
vsync rather than losing it). `CTRL_RB` gained a matching bit 2 readback.
**User will verify CPLD fit** (Yosys/ATF1508 toolchain not set up here).
Software side: mirrored into the emulator's `VideoState` (easy to forget --
the Verilog/yml change alone did nothing until the C++ model matched), and a
new minimal `drivers/video/fbdev/griffin_video.c` (`CONFIG_FB_GRIFFIN`, DT node
now `status = "okay"`) that ack-only-handles vsync: `devm_request_irq()` THEN
write `CTRL=IRQENB` (only after the handler exists), never touching ENABLE
(video stays off; M9 extends this same file into the real fbdev driver). Since
IRQENB now defaults masked, a `platform_driver` probing late (well after the
kernel's own early interrupt-enable, unlike TIMER_OF_DECLARE's early init) is
safe -- the whole point of the bit is removing that timing dependency, not
just moving the race around.

### Bug 2: kernel never told the CPU to look at its own vector table

After fixing the vsync IRQ, kernel still made no progress once the timer IRQ
started firing -- but now with a genuine CPU-state abort (register/memory
corruption spiralling into an unmapped write) instead of a silent livelock,
i.e. clearly a *different* bug once the first one was out of the way.
Diagnosis: `mc68010_intc_of_init()` (`arch/m68k/68000/ints_generic.c`)
populates `_ramvec[i] = ...` (real handler addresses) at `*_ramvec`
(`extern e_vector *_ramvec;`, a pointer -- its value is `CONFIG_VECTORBASE`,
0 for Griffin, set once in `head.S`) -- but **never issues `movec` to point the
68010's actual VBR register there**. That's harmless on stock boards where
firmware/bootloader leaves VBR at its reset value (0, matching
CONFIG_VECTORBASE) the whole time. But Griffin's u-boot *deliberately* moves
VBR away from 0 (`arch_initr_trap`, M3/M4 fix) to protect its own vectors
before `bootelf` loads the kernel at physical 0 -- so the kernel inherits a
non-zero VBR pointing at u-boot's now-overwritten (by kernel code/stack)
former vector table. Instruction execution never consults VBR, so the kernel
ran fine right up until the first real exception (the timer IRQ): the CPU then
fetched its handler through stale/garbage memory and jumped into garbage,
producing the corrupted-SP, unmapped-write abort (confirmed via gdb backtrace
+ the emulator's own `dump_cpu_state()`, added by factoring the existing
`GRIFFIN_DUMP_ON_EXIT` dump into a method also called from all four
unhandled-access `abort()` sites so a crash prints full CPU state instead of
requiring gdb).

**Fix:** `set_vbr_68010()` (same hand-encoded `.word 0x4e7b, 0x0801` movec as
u-boot's, since this tree also compiles `-m68000` with no compiler-level
movec support) added to `mc68010_intc_of_init()`, called with `(unsigned long)
_ramvec` right after the vector-table population loops -- correct and
sufficient regardless of what CONFIG_VECTORBASE happens to be, and a no-op on
boards where VBR was already 0.

### Result

Full boot: earlycon log -> `Calibrating delay loop... 1.20 BogoMIPS` (proves
the tick fires) -> `VFS: Finished mounting rootfs on nullfs` -> video driver
probes cleanly -> reaches the **expected** M6/M7 boundary:
`Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)`
(no CF kernel driver / root fs yet -- that's M7).

## M7 outcome (CF block driver + erofs root mount; kernel reaches the M8 boundary)

**Deliverable:** `drivers/block/griffin_cf.c` (`CONFIG_GRIFFIN_CF`, DT
`griffin,cf-ide`, no IRQ -- fully polled) -- a THIRD independent port of the
same 8-bit True IDE PIO protocol (firmware, u-boot, now kernel), using the
modern `blk_mq` API (`blk_mq_alloc_sq_tag_set` + `blk_mq_alloc_disk` +
`.queue_rq`, `BLK_MQ_F_BLOCKING` since I/O is synchronous polling with no IRQ).
Structural template: LinuxMD's `everdrive_blk.c` (already in-tree, gated off
for Griffin since M2). Read AND write supported (cheap to add, keeps the
driver usable for a future writable data partition per the design doc), disk
named `cf` (not `sda` -- this isn't a SCSI/SATA-shaped disk, matching how e.g.
eMMC uses `mmcblk0` rather than pretending to be `sda`).

One real bug (`struct gendisk` has no `queuedata` member -- that's a
`request_queue` field; `blk_mq_alloc_disk()`'s third arg already becomes
`queue->queuedata`, confirmed from the header, no need to set it again) and
two environment-only speed bumps (both **not kernel bugs**, worth remembering
for the emulator harness):

- **CF now needs a real partition table.** M1-M6 tested against a raw/
  superfloppy FAT16 image (no MBR) so u-boot's `fatload ide 0:0 ...` ("device
  0, whole disk") found the boot files directly. Root needs its own partition,
  so `cf.img` is now `sfdisk`-partitioned: MBR, partition 1 = FAT16 boot
  (`u-boot.bin`, `vmlinux`) at sector 2048 (24 MiB), partition 2 = erofs root
  at sector 51200 (15 MiB). Once a real MBR exists, `0:0` no longer resolves
  (sector 0 is now the MBR, not a FAT boot sector) -- u-boot's `bootcmd` had
  to move to `0:1` (`include/configs/griffin.h`).
  Build recipe: `sfdisk cf.img < layout` (dos label, `type=e`/`type=83`),
  `mkfs.fat -F16 --offset=2048 cf.img 24576` (block count is 1024-byte units,
  so KiB not sectors), `mcopy -i "cf.img@@1M" file ::` (mtools' `@@offset`
  addressing for partitioned images), `dd ... seek=51200 conv=notrunc` to drop
  a `mkfs.erofs`-built image at partition 2's byte offset.
- **`root=/dev/sda2` was a copy-paste default from M2** that never mattered
  until a real block device existed. Fixed to `root=/dev/cf2` in both
  `griffin.dts` copies, matching the driver's actual disk name.

### Result

Full boot: earlycon -> BogoMIPS -> `cf: cf1 cf2` (partition scan) ->
`griffin-cf f40000.ide: 81920 sectors (40 MiB)` ->
`erofs (device cf2): mounted with root inode @ nid 36` ->
`VFS: Mounted root (erofs filesystem) readonly on device 259:2` ->
`VFS: Pivoted into new rootfs` -> tries `/sbin/init`, `/etc/init`, `/bin/init`,
`/bin/sh` in turn -> **expected** M7/M8 boundary:
`Kernel panic - not syncing: No working init found.` (root image is currently
just a placeholder `README`; M8 puts real userspace there.)

## M8 outcome (busybox init + interactive hush shell on the DUART)

Working session: init -> rcS ("Griffin: userspace up.", mounts /proc + /sys)
-> interactive hush on ttyS0 -> uname/ls/ps/pipelines all execute.  First
real exercise of the DUART driver's interrupt RX path, which worked as built.
Four lessons, each of which cost a debugging round:

1. **musl cannot produce flat userspace** (detailed in README): its crt
   assumes the ELF stack layout; binfmt_flat passes argc/argvp/envpp instead.
   A musl-linked init faults before main(), and a faulting init is unkillable
   -> the machine "hangs" in a silent SIGSEGV storm (diagnosed by sampling
   PC: always inside prepare_signal/__send_signal_locked).  Userspace uses a
   second buildroot toolchain: m68k-buildroot-uclinux-uclibc (uClibc-ng has
   the flat-aware crt).  Required adding a BR2_m68k_68000 CPU variant to
   buildroot (stock only has MMU-forcing 68030/68040 + ColdFire, making
   BR2_BINFMT_FLAT unreachable).  The uclinux toolchain emits bFLT by
   default; FLTFLAGS="-r -s 65536" sets load-to-RAM + stack size.
2. **ash does not exist on nommu** -- busybox hard-errors ('#error "Do not
   even bother, ash will not run on NOMMU machine"').  hush is the nommu
   shell; its subshells/pipelines re-exec busybox via /proc/self/exe, so
   /proc must be mounted early (rcS does it first).
3. **busybox's ancient kconfig ignores KCONFIG_ALLCONFIG values under
   allnoconfig** -- it loads them as *defaults*, then answers "n" to every
   question anyway; only `choice` selections (SH_IS_HUSH) survive.  This
   produced a shell-only busybox that looked half-working (hush ran, no
   applets) before the root cause was found via `conf`'s verbose transcript
   (`SHOW_USAGE [Y/n/?] n` -- fragment default visible, overridden).
   buildrootfs.sh now merges the fragment textually into .config and runs
   `yes "" | make oldconfig`, then asserts key symbols survived.
4. **CONFIG_BINFMT_SCRIPT=y is required** for `#!` scripts (rcS).  The
   megadrive defconfig this grew from leaves it off (smolutils execs no
   scripts); without it execve fails ENOEXEC and busybox init retries the
   path as an applet name ("rcS: applet not found"), leaving /proc unmounted
   -- which also breaks hush pipelines (lesson 2).

Rootfs: buildrootfs.sh (busybox flavor default; ROOTFS_FLAVOR=smolutils
keeps the LinuxMD fallback) -> 280 KB busybox, all applet links via
`make install CONFIG_PREFIX=skel`, inittab (sysinit rcS + askfirst sh),
erofs ~280 KB.  Follow-up agreed with the user: ext2 rw root option
(mke2fs -d, unprivileged) once M8/M9 settle; kernel CF driver already
does writes.

## M9 — fbdev console, and the DMA-stall boot wedge

The fbdev driver (`drivers/video/fbdev/griffin_video.c`) came up quickly:
640x480x1 `FB_VISUAL_MONO10`, 84-byte stride, `screen_base = fb + 4` for the
in-band palette header, reserved-memory carveout at 0x7f0000, vsync-ack IRQ
handler, ENGINE->VIDEO enable order on probe. One real kernel bug found and
fixed along the way: **reserved-memory was cataloged but never reserved** —
`setup_arch()` on M68KDT didn't call `early_init_fdt_scan_reserved_mem()`, so
`mem_map` landed in the framebuffer carveout and got shredded once DMA
streamed it to the screen. Added that call in `arch/m68k/kernel/setup_dt.c`
(generic fix for all M68KDT boards).

The hard part was a boot **wedge**: with the fbdev driver enabling ENGINE DMA,
boot intermittently hung right after `random: crng init done`,
nondeterministically. Debugging chain and conclusions:

- **Not frozen ticks.** A `GRIFFIN_DUMP_ON_EXIT` CPU dump caught the wedged CPU
  mid-`__schedule` *inside a normal 100 Hz timer tick* (`griffin_duart_isr ->
  tick_periodic -> sched_tick -> task_tick_fair`, `SR` IPL mask = 5). Ticks are
  firing.
- **Not TX starvation** (emulator DUART TXRDY is always ready) and **not
  fbcon rendering** (wedges with `console=ttyS0` only, no fbcon).
- **Not livelock.** The fp backtrace (depth raised to 40 to reach through the
  IRQ frame) showed the interrupted context was a kernel thread parked in
  `kthread()`'s *initial* `schedule()` — i.e. a freshly-created kthread waiting
  for its first `wake_up_process()`, never run. Matches the earlier symptom of
  `maybe_create_worker -> wait_for_completion_killable` hanging: the CPU idles
  (taking ticks) while a wakeup is stuck.
- **Cause = the emulator's coarse DMA-stall model.** `service_video()` charged
  the whole per-scanline burst as one `sync(SYSCLKS_PER_LINE)` lump in the gap
  between two whole instructions — fast-forwarding the shared clock ~a dozen
  instructions' worth in a single interrupt-blind gap, at the video-scanline
  cadence. That video-phased clock discontinuity mis-times the scheduler wakeup
  on the nommu/UP kernel.
- **Proven it's the discontinuity, not the slowdown.** Distributing the
  *identical total* stall across instructions (a few cycles per CPU step) boots
  cleanly to a busybox shell; the lump wedges. So it is the per-lump *magnitude*
  (threshold sat between the 93-cycle cost after the 2-cyc/word ENGINE change
  and the earlier 141-cycle cost), not the CPU-vs-jiffies slowdown, which is
  identical either way.

Fix: the emulator now delivers the stall **smoothly** by default (debt paid
down `GRIFFIN_DMA_STALL_STEP` cycles/step), which is also what real hardware
does — ENGINE steals the bus at bus-cycle granularity via BR/BG/DTACK, never in
one interrupt-blind lump. The old lump is kept behind `GRIFFIN_DMA_STALL_LUMP`
for A/B and intra-line tearing studies. **No Griffin hardware or kernel change
was needed** — the wedge was purely a modeling artifact with no hardware
analog. fbcon now boots to a shell with DMA live the whole time.

## Issue #4 — standalone boot (u-boot video/kbd, kernel PS/2): findings

- **u-boot relocation already overlapped the fb carveout.** With 8 MB and no
  ram-top cap, relocated u-boot's bss ran to ~0x7ff088 — inside
  0x7f0000-0x7fffff. Harmless while nothing used the carveout during u-boot's
  lifetime; fatal once u-boot renders there. `board_get_usable_ram_top()` →
  0x7f0000.
- **u-boot generic vidconsole is 8/16/32bpp only** (`check_bpix_support`);
  `VNBYTES(VIDEO_BPP1)=0` silently no-ops its drawing math. Custom
  `vidconsole_ops` driver is the supported escape hatch — the uclass keeps
  all cursor/newline/scroll bookkeeping.
- **This fork's `fonts[]` has the 8x8 font first, unconditionally**
  (`include/video_font.h` — the `#if CONFIG_VIDEO_FONT_8X8` guard is
  commented out). `console_probe()` takes `fonts[0]`, so text rendered
  squeezed/overstruck at 8-pixel row pitch until the driver re-selected
  "8x16" via `console_simple_select_font()`.
- **`CONFIG_VIDEO_ANSI` off makes `\e[2K` print literally** on the display
  (autoboot countdown spam). On.
- **`video_clear()` wipes the in-band palette headers** (memsets the whole
  fb, headers included) — the `video_sync` op restamps them behind a
  line-0-fg sentinel. Without the restamp the screen renders black-on-black.
- **LTO + basic asm gotcha:** `__asm__ volatile("ori.w #0x0700,%%sr")` with
  *no operand lists* is basic asm — `%%` is not collapsed, and the assembler
  error surfaces only at the LTO link ("bad expression ... invalid operands
  for `%`"). Add `::: "cc"` (extended asm) or use single `%`.
- **u-boot really does run at SR=0x2700 throughout** — confirmed empirically
  with a mid-autoboot-countdown `GRIFFIN_DUMP_ON_EXIT` dump, settling the
  IPL-0 question from planning. The ROM's still-installed vector table never
  executes under u-boot; PS/2 bytes simply latch until polled.
- **Autoboot countdown runs ~2.5-3.5 s after power-on** (emulated) — much
  earlier than the naive log-based estimate, because u-boot's own "bytes read
  in 13 ms" timing is wrong (the polled CF fatload of a 1.7 MB kernel
  actually spans ~10 emulated seconds). Two "keyboard doesn't interrupt
  autoboot" false alarms were both injection-timing errors; the driver was
  fine (proved by forcing a prompt via a vmlinux-less CF image and typing
  `version` by keyboard).
- **Kernel side was drama-free:** altera_ps2-shaped serio port + atkbd, with
  the vsync-style W1C ack discipline. atkbd accepts the port with a real
  `->write`; the emulator's new PS/2 device-command responses (0xFF→FA+AA,
  0xF2→FA AB 83, 0xED/0xF3/0xF4→FA) let the full GETID probe run headless.
  Mid-session `raw AA` (the repeated-BAT case Brad has seen on real
  hardware) recovers via atkbd reconnect; typing continues.

## Base configs to crib from

- `arch/m68k/configs/megadrive_defconfig` — closest working M68KDT nommu config.
- `arch/m68k/configs/virt_mc68000_defconfig` — generic 68000 virt.
No `.dts` files ship under `arch/m68k/` (DTB comes from u-boot/d7), so `griffin.dts`
+ its `.dtb` build live in the superproject / u-boot side; u-boot embeds/loads it.
