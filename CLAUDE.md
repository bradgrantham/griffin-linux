For Griffin project specifics, @griffin/CLAUDE.md

# Linux port (this superproject)

* docs/linux-port.md is the design of record for the Linux port — the boot
  chain, the two-toolchain split (musl for kernel/u-boot, m68k-uclinux
  uClibc-ng for bFLT userspace), driver architecture, and how the as-built
  approach differs from griffin/linux-port-design.txt (the original proposal).
  Read it before changing the boot flow, DTs, or drivers.
* docs/boot-handoff-notes.md is the chronological findings/debugging log
  (M2-M7): entry contracts, emulator harness recipes, and root-cause writeups
  for the bugs hit along the way. Append new findings there; distill durable
  design facts into docs/linux-port.md.
* The authoritative griffin.dts lives in u-boot/arch/m68k/dts/ (embedded via
  OF_EMBED, passed to the kernel in d7); dts/griffin.dts here is a hand-synced
  reference copy. Edit both when either changes.
