# SPDX-License-Identifier: GPL-2.0-only
# Standalone build of the LZ4HC crypto compressor for zram.
#
# 与 lz4k 那几个不同，这个模块**不内嵌编解码器**：
# lib/lz4/lz4hc_compress.c 和 lib/lz4/lz4_decompress.c 在厂商内核里通常
# 已经编进 vmlinux（CONFIG_LZ4HC_COMPRESS=y / CONFIG_LZ4_DECOMPRESS=y），
# 而且 LZ4_compress_HC() 与 LZ4_decompress_safe() 都是 EXPORT_SYMBOL，
# 模块可以直接调用。缺的只是 crypto 那一层注册胶水（CONFIG_CRYPTO_LZ4HC
# 没开），这正是本模块补的东西。
obj-m += lz4hc.o
lz4hc-y := lz4hc_crypto.o
