# Makefile for the miscfifo misc character device.
#
# Usage:
#   make                Build miscfifo.ko for the running kernel (native)
#   make clean          Remove build artifacts
#
# Cross-compiling for Jetson (or another ARM64 target):
#   make ARCH=arm64 \
#        CROSS_COMPILE=aarch64-linux-gnu- \
#        KDIR=/path/to/jetson/kernel/source
#
# Do not pass ARCH= or CROSS_COMPILE= when empty — kbuild treats ARCH="" as
# invalid (arch//Makefile). Native builds omit them entirely.
#
# Prerequisites for cross-compilation:
#   sudo apt install gcc-aarch64-linux-gnu

obj-m += miscfifo.o

KDIR ?= /lib/modules/$(shell uname -r)/build

# Only forward ARCH / CROSS_COMPILE when set (see note above).
kbuild_extra :=
ifneq ($(strip $(ARCH)),)
kbuild_extra += ARCH=$(ARCH)
endif
ifneq ($(strip $(CROSS_COMPILE)),)
kbuild_extra += CROSS_COMPILE=$(CROSS_COMPILE)
endif

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(kbuild_extra) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(kbuild_extra) clean
