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

static bool sw842_template_counts;
module_param_named(template_counts, sw842_template_counts, bool, 0444);

static atomic_t template_count[OPS_MAX], template_repeat_count,
	template_zeros_count, template_short_data_count, template_end_count;

#endif