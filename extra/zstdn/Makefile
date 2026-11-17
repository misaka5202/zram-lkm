# SPDX-License-Identifier: GPL-2.0-only
# zstdn / zstdn_o 压缩算法模块。
#
# 与 lz4hc 同类：内核里已经编进了 zstd 编解码器并导出了单遍 API
# （zstd_get_params / zstd_cctx_workspace_bound / zstd_init_cctx /
#  zstd_compress_cctx 及其 dctx 对应物），所以这里只做注册，不带编解码器。
#
# 与 OPPO 原版的区别：OPPO 把整套 zstd（27 个文件）编进自己的模块，因为他们
# 是树外构建且那份 zstd 是改过的；这里直接用内核自带的，只是驱动在 level 1。
obj-m += zstdn.o
zstdn-y := zstdn_crypto.o $(KR_OBJS)

# KallRecon：运行时解析未导出符号（与 droidspaces-lkm 的 cgrouplimits 同源）
KR_OBJS := kallrecon/core.o kallrecon/access.o kallrecon/discover.o kallrecon/symbol.o kallrecon/slide.o kallrecon/fastboot.o kallrecon/hint.o kallrecon/variant.o kallrecon/anchor.o
ccflags-y += -Wno-declaration-after-statement -Wno-unused-variable -Wno-unused-function -Wno-strict-prototypes -Wno-gcc-compat -Wno-incompatible-function-pointer-types
