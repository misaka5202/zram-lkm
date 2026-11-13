# SPDX-License-Identifier: GPL-2.0-only
# Standalone build of the LZ4KD crypto compressor for zram.

ccflags-y += -I$(src)/include -DLZ4K_DELTA -O3

obj-m += lz4kd.o
lz4kd-y := lz4kd_crypto.o lz4kd_encode.o lz4kd_decode.o lz4kd_encode_delta.o lz4kd_decode_delta.o
