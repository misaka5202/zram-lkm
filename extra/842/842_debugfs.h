/* SPDX-License-Identifier: GPL-2.0 */
/*
 * [TRIMMED] 精简版 842 统计头。
 *
 * 原版 lib/842/842_debugfs.h 除了这些计数变量，还定义 debugfs_create_dir /
 * debugfs_remove 那些只在"842 单独作为模块、且 CONFIG_842_DEBUG 打开"时才
 * 用得上的函数。我们把编解码器嵌进自己的 .ko，不需要 debugfs，而且那些
 * static 函数会因为没人调用而触发 -Werror=unused-function。
 *
 * 这里只保留编解码器真正引用的统计变量，并把计数开关做成只读模块参数，
 * 保持"默认关闭统计"的原行为。
 */

#ifndef __842_STATS_TRIMMED_H__
#define __842_STATS_TRIMMED_H__

#include <linux/atomic.h>
#include <linux/module.h>
#include <linux/types.h>

/*
 * [DUPLICATE-PARAM] 这里**不能**用 module_param_named：本头文件同时被
 * 842_compress.c 和 842_decompress.c include，宏会在两个编译单元里各生成
 * 一份 sysfs 参数，内核加载模块时报
 *   sysfs: cannot create duplicate filename
 *          '/module/842/parameters/template_counts'
 * 直接 -EEXIST 失败（而且是模块加载阶段，走不到 init，dmesg 里连我们的
 * 打印都看不到）。
 *
 * 统计本来就默认关闭、只为调试，所以干脆不要这个参数：两个 TU 各自持有一份
 * static bool，恒为 false，模板统计不启用，行为与原版默认一致。
 */
static bool sw842_template_counts;

static atomic_t template_count[OPS_MAX], template_repeat_count,
	template_zeros_count, template_short_data_count, template_end_count;

#endif