# Griffin Linux superproject.  Clone, then run the stages in order:
#
#   git submodule update --init
#   make toolchain   # buildroot -> m68k-linux uClibc-ng cross toolchain
#   make uboot       # second-stage bootloader (Griffin board)
#   make linux       # nommu kernel -> vmlinux + vmlinux.lz4 + griffin.dtb
#   make rootfs      # erofs root filesystem image
#   make cfimage     # assemble u-boot + kernel + rootfs into a bootable cf.img
#
# 'make all' runs all five.  Each stage is a thin wrapper script so they can
# also be run individually for iterative bring-up.

.PHONY: all toolchain uboot linux rootfs cfimage config submodules

all: toolchain uboot linux rootfs cfimage

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

cfimage:
	./buildcfimage.sh

config:
	./configlinux.sh
