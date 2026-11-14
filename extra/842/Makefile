# SPDX-License-Identifier: GPL-2.0-only
# 842 压缩算法的树外模块。
#
# 与 lz4hc 不同，这个模块**内嵌编解码器**：厂商内核通常把
# CONFIG_CRYPTO_842 和 CONFIG_842_COMPRESS 一起裁掉，lib/842 根本没编进
# vmlinux，没有导出符号可复用。所以把 lib/842 的源码带进来直接编译。
# （lib/842 明确标注是"参考实现，非常慢"，仅作算法可用性补齐。）
#
# 不是必须装：只有内核缺 842 时它才有意义；已内置 842 的内核上加载会因为
# 名字已被占用而失败，KSU 加载脚本会跳过。
obj-m += 842.o
842-y := 842_crypto.o 842_compress.o 842_decompress.o
