# Griffin Linux superproject.  Clone, then run the four stages in order:
#
#   git submodule update --init
#   make toolchain   # buildroot -> m68k-linux uClibc-ng cross toolchain
#   make uboot       # second-stage bootloader (Griffin board)
#   make linux       # nommu kernel -> vmlinux + vmlinux.lz4 + griffin.dtb
#   make rootfs      # erofs root filesystem image
#
# 'make all' runs all four.  Each stage is a thin wrapper script so they can
# also be run individually for iterative bring-up.

.PHONY: all toolchain uboot linux rootfs config submodules

all: toolchain uboot linux rootfs

submodules:
	git submodule update --init --recursive

toolchain:
	./buildtoolchain.sh

uboot:
	./builduboot.sh

linux:
	./buildlinux.sh

rootfs:
	./buildrootfs.sh

config:
	./configlinux.sh
