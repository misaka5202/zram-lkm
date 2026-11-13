# SPDX-License-Identifier: GPL-2.0-only
# Standalone build of the LZ4K crypto compressor for zram.

ccflags-y += -I$(src)/include

obj-m += lz4k.o
lz4k-y := lz4k_crypto.o lz4k_encode.o lz4k_decode.o
