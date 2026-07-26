# Griffin boot cheat-sheet

## Kernel bootargs
Live in `chosen/bootargs` of `u-boot/arch/m68k/dts/griffin.dts` (embedded in
u-boot — **rebuild u-boot to change**; keep `dts/griffin.dts` synced).

- `console=tty0 console=ttyS0` — consoles; **last one = /dev/console**
  (owns init's output). Any subset. **Real HW: drop `console=ttyS0` or add
  `quiet`** — printk waits for serial at 115200 (~11.5 KB/s) and gates boot.
- `quiet` / `loglevel=N` — mute console output (dmesg still captures all).
- `earlycon` — early *serial* console via stdout-path; remove to silence.
  The framebuffer boot console needs no parameter (self-registers, one
  visual reset at fbcon takeover + full log replay).
- `keep_bootcon` — keep boot consoles past real-console registration (debug).
- `root=/dev/cf2 rootfstype=ext2 rw` — writable ext2 root (`cf1` = FAT boot partition).
- `initcall_debug ignore_loglevel` — boot tracing / benchmarking.

## u-boot (prompt: any key in the 2 s autoboot window; PS/2 works, serial-in is flaky — M3 note)
Env resets every boot (`ENV_IS_NOWHERE`); defaults in `include/configs/griffin.h`.

- `setenv stdout serial,vidconsole` / `stdin serial,kbd` / `stderr …` — any subset.
- `bootcmd=fatload ide 0:1 0x400000 vmlinux; bootelf -p 0x400000` — the boot.
- `bootdelay` (CONFIG_BOOTDELAY=2) — autoboot window; costs 2 s per boot.
- Output before console init (banner, DRAM, `In:/Out:`) is serial-only — inherent.

## ROM monitor (PS/2 keyboard or serial)
- `run U-BOOT.BIN` boots the chain; `help`, `ls`, `read/write ADDR`, `view IMG PAL`.
- Screen persists: ROM → u-boot → kernel early console append (no clears);
  fbcon takeover is the one reset (then replays the whole kernel log).

## Shells / accounts (buildrootfs.sh inittab + skeleton)
- `ttyS0::askfirst:-/bin/sh` (serial) + `tty1::askfirst:-/bin/sh`
  (display+PS/2); login shells source `/etc/profile` (PATH, PS1, motd).
- `login`/`getty`/`passwd`/`su` are built and work from a shell; init-spawned
  getty/login stall ~60 s before prompting (tracked — see handoff notes),
  hence askfirst.
- Entropy: rcS runs `seedrng` against the persisted `/var/lib/seedrng` seed —
  without it anything calling getrandom() blocks ~2.5 min for crng init.

## Images
- `./buildlinux.sh` → vmlinux; `./builduboot.sh`; `./buildrootfs.sh` →
  rootfs.ext2 (writable, fakeroot+mke2fs -d; ROOTFS_FLAVOR=smolutils for the
  erofs fallback); `ROOTFS_IMAGE=rootfs.ext2 OUT=cf.img ./buildcfimage.sh` →
  bootable CF (p1 FAT16: U-BOOT.BIN+vmlinux; p2 root).

## Emulator
- Interactive: `emulator --cf cf.img rom.bin` — SDL window = display+PS/2
  keyboard, pty = serial. Type `run U-BOOT.BIN` in either.
- Unattended: `--headless --console-in/-out F (or --console-stdio)
  --ps2-in script --no-throttle --run-cycles N --screenshot f.bmp`.
- PS/2 script: `delay MS` | `text STRING` (`\r` etc.) | `raw HH..`
  (`raw AA` = fake keyboard BAT).
- Env: `GRIFFIN_DUMP_ON_EXIT=1`, `GRIFFIN_DUMP_RAM=addr:len`,
  `GRIFFIN_NO_DMA_STALL`, `GRIFFIN_DMA_STALL_LUMP` (old model), `GRIFFIN_DMA_STALL_STEP=N`.

## Real-hardware cautions
- Serial console gates printk at 115200 — see bootargs above.
- PS/2 host-TX timing (CLK-inhibit ≥100 µs) follows the firmware recipe but
  is unverified on silicon; emulator ACKs everything.
- The keyboard re-sends BAT (0xAA) if never configured — u-boot and the
  kernel both recover (re-enable / atkbd reconnect).
