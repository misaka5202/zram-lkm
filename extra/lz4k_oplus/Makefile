# SPDX-License-Identifier: GPL-2.0-only
# Standalone build of the LZ4K_OPLUS crypto compressor for zram.

ccflags-y += -I$(src)/include

obj-m += lz4k_oplus.o
lz4k_oplus-y := lz4k_oplus_crypto.o lz4k_compress.o lz4k_decompress.o
