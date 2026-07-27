# Paste-ready GitHub issue drafts

(Working notes — delete entries as they get filed.)

---

## ROM-resident root filesystem for PCB rev 2

Store the root filesystem in physical ROM/flash on the rev 2 board, paired
with XIP so binaries execute in place. This eliminates the two structural
costs of nommu exec on Griffin: the per-exec full-image copy into RAM and
the CF cold-load. Interim step possible on rev 1: XIP romfs-in-RAM (classic
uClinux layout; `drivers/mtd/maps/uclinux.c` is in-tree), which already
removes the per-exec copy and the order-7 contiguous allocation.

Background data: `time /bin/true` = 7.5 s, sys-bound; profiler shows ~30%
memcpy/memset (image copies). See docs/boot-handoff-notes.md.

## Generalize ENGINE into a DMA engine (memmove/memset/scroll accel)

Evolve the ENGINE CPLD from a framebuffer streamer into a general DMA engine
that can accelerate memmove, memset, and framebuffer scrolling. Would attack
the ~30% memcpy/memset share of exec cost and make fbcon scrolling
effectively free. First step per project rules: verify the added logic fits
the ATF1508 before touching software.

## Investigate/tune __div64_32 (PELT scheduler math)

~11% of exec-window profile samples land in `__div64_32` + PELT
(`decay_load`, `__update_load_avg_*`): the scheduler's load tracking does
64-bit divides, and m68k hardware divide is only 32/16, so the generic C
loop grinds at 14 MHz. Candidates: hand-tuned m68k asm div64 in
arch/m68k/include/asm/div64.h for the nommu case, or configuration to
reduce PELT update frequency. Measure with the emulator PC profiler
(GRIFFIN_PROFILE=START:END).

## Exec latency umbrella: XIP, drop BINFMT_ELF_FDPIC, hush re-exec

`time /bin/true` = 7.5 s (sys 7.0). Profiler breakdown
(docs/boot-handoff-notes.md): ~30% memcpy/memset (nommu full-image copies,
doubled by hush standalone re-exec for non-NOFORK applets), ~18% PELT
software division, ~8% binfmt_flat proper, ~3% load_elf_fdpic_binary
(CONFIG_BINFMT_ELF_FDPIC is enabled by default and probes/rejects every
exec — free win to disable). Fixes ranked: XIP romfs (see ROM-rootfs
issue), disable BINFMT_ELF_FDPIC, reconsider hush STANDALONE re-exec,
div64 tuning (own issue).

## init-spawned getty/login stall ~60 s (tty-attached init children only)

busybox getty AND login stall ~60 s before their first prompt when spawned
from a tty-field inittab entry (init child = session leader WITH ctty →
the TIOCNOTTY/ctty-steal path). A/B: `exec getty` from rcS (session leader,
NO ctty) prompts instantly; `sh -c getty` wrapper does not help. Suspect
kernel ctty/vhangup interaction. Current workaround: askfirst shells;
login/getty/passwd/su all work from a running shell. Full A/B data in
docs/boot-handoff-notes.md.
