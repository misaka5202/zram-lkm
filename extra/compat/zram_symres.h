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
 * 本文件是 zram-lkm 全部五个模块**唯一**的符号解析入口：lz4hc / 842 / zstdn
 * 用 ZR_SYM / ZR_REQUIRE，zram_list 直接调 zr_lookup。此前 zram_list 另有一份
 * 逐字相同的 kprobe 探测实现，已并入这里（同一个模式抄两遍，改一处漏一处）。
 *
 * 两条解析途径，按顺序降级
 * ----------------------
 * 1. KallRecon（extra/kallrecon/，与 droidspaces-lkm 的 cgrouplimits 同源）：
 *    直接解析内核的 kallsyms 表拿 kallsyms_lookup_name，**不依赖 kprobe**。
 *    顺带解决 kprobe 的两个短板：kptr_restrict 无关（不走 /proc/kallsyms），
 *    且不受 kprobe 黑名单限制（aarch64_insn_patch_text_nosync 这类也能查到）。
 * 2. kprobe 探测：KallRecon 不可用（布局探测失败）时的回退，行为同改动前。
 *
 * 因为第 1 条存在，绝大多数内核上 kprobe 探测路径**根本不会执行** ——
 * 运行期已不再依赖 kprobe。但 register_kprobe 的链接期引用刻意保留：
 * KallRecon 万一布局探测失败时，静态链接的 kprobe 是唯一退路，去掉它
 * （同名转发）会把"多一条路"变成"少一条路"。register_kprobe 是
 * EXPORT_SYMBOL_GPL，CONFIG_KPROBES=y 的 GKI 内核都会导出，缺失极少见。
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

/* KallRecon 的入口。这里只 extern 声明而不 include "kallrecon/core.h" ——
 * 头文件路径会随调用方目录变化（staging 后 kallrecon/ 在各模块目录下），
 * 重复声明与 core.h 一致即可，和 cgrouplimits/common.c 同一处理。 */
extern unsigned long (*kallrecon_klp)(const char *name);
extern void find_kallsyms_base(void);

/* 每个编译单元各有一份，模块内不会冲突 */
static zr_kln_fn zr_kln;
static bool zr_kr_tried;

static void zr_kr_init(void)
{
	if (zr_kr_tried)
		return;
	zr_kr_tried = true;
	/* 幂等：core.c 内部用 ks_done 保证只探测一次 */
	find_kallsyms_base();
}

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
	zr_kr_init();

	/* 首选 KallRecon：不依赖 kprobe，也不受 kprobe 黑名单限制 */
	if (kallrecon_klp)
		return kallrecon_klp(name);

	/* 回退：kprobe 探测（KallRecon 布局探测失败时） */
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