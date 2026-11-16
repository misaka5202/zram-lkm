/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * zram_symres.h - 运行时符号解析，给 vendor 内核没导出符号时兜底
 *
 * 背景
 * ----
 * 部分厂商内核把 crypto/zstd/lz4 的辅助函数裁掉了 EXPORT_SYMBOL，但函数
 * 本体仍在 kallsyms 里（CONFIG_KALLSYMS_ALL=y）。这种情况下静态链接会让
 * 整个模块装不上，而运行时解析能正常工作。
 *
 * 已确认的机型和缺口：
 *   Qualcomm SM7675 / 6.1.138  crypto_register_scomp /
 *                              crypto_unregister_scomp /
 *                              LZ4_compress_HC / LZ4_decompress_safe /
 *                              zstd_get_params 等 10 个 zstd API
 * 这些名字在本机都存在，只是不在 __ksymtab 里。
 *
 * 机制
 * ----
 * 先用 kprobe 的 symbol_name 查一次 kallsyms_lookup_name（它本身在 kprobe
 * 白名单里），拿到之后所有符号都交给它查 —— kprobe 只能找到"可探测"的函数，
 * 而 kallsyms_lookup_name 能查 kallsyms 里的任何东西。
 *
 * 和 zram_list_main.c 里那套是同一个做法，这里抽出来给三个 crypto 模块共用。
 *
 * CFI 注意
 * --------
 * CONFIG_CFI_CLANG=y 的内核会在**间接调用点**做类型检查。通过这里解析出来的
 * 函数指针调用时，调用者必须标 __nocfi，否则会被 kCFI 拒绝执行。
 */

#ifndef _ZRAM_SYMRES_H
#define _ZRAM_SYMRES_H

#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/string.h>

#ifndef __nocfi
#define __nocfi
#endif

typedef unsigned long (*zr_kln_fn)(const char *name);

/* 每个编译单元各有一份，模块内不会冲突 */
static zr_kln_fn zr_kln;

static unsigned long zr_lookup_probe(const char *name)
{
	struct kprobe kp;
	unsigned long addr;

	memset(&kp, 0, sizeof(kp));
	kp.symbol_name = name;
	if (register_kprobe(&kp))
		return 0;
	addr = (unsigned long)kp.addr;
	unregister_kprobe(&kp);
	return addr;
}

static unsigned long zr_lookup(const char *name)
{
	if (!zr_kln)
		zr_kln = (zr_kln_fn)zr_lookup_probe("kallsyms_lookup_name");
	if (zr_kln)
		return zr_kln(name);
	return zr_lookup_probe(name);
}

/* 解析一个，失败留 NULL */
#define ZR_SYM(slot, name)						\
	do {								\
		if (!(slot))						\
			(slot) = (void *)zr_lookup(#name);		\
	} while (0)

/* 解析一个，失败直接返回 -ENOENT（只在 init 里用） */
#define ZR_REQUIRE(slot, name)						\
	do {								\
		ZR_SYM(slot, name);					\
		if (!(slot)) {						\
			pr_err("[zram] 无法解析符号 %s，本内核未导出且不可查\n", \
			       #name);					\
			return -ENOENT;					\
		}							\
	} while (0)

#endif /* _ZRAM_SYMRES_H */