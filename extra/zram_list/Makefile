# SPDX-License-Identifier: GPL-2.0-only
# KallRecon：运行时解析未导出符号（与 droidspaces-lkm 的 cgrouplimits 同源）
KR_OBJS := kallrecon/core.o kallrecon/access.o kallrecon/discover.o kallrecon/symbol.o kallrecon/slide.o kallrecon/fastboot.o kallrecon/hint.o kallrecon/variant.o kallrecon/anchor.o
obj-m += zram_list.o
zram_list-y := zram_list_main.o $(KR_OBJS)
ccflags-y += -Wno-declaration-after-statement -Wno-unused-variable -Wno-unused-function -Wno-strict-prototypes -Wno-gcc-compat -Wno-incompatible-function-pointer-types
