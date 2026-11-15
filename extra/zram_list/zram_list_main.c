// SPDX-License-Identifier: GPL-2.0-only
/*
 * zram_list - make module-loaded compressors show up in
 * /sys/block/zramN/comp_algorithm
 *
 * The problem
 * -----------
 * zram validates a compressor name with crypto_has_comp(), so any algorithm the
 * crypto API knows works -- that is why this project's modules are usable at
 * all. But the *list* the sysfs file prints comes from a different place:
 *
 *   static const char * const backends[] = { "lzo", "lzo-rle", "lz4", ... };
 *
 * zcomp_available_show() walks that array and nothing else. It is fixed at
 * build time, so every algorithm a module adds works but stays invisible. Users
 * read that file to see what they can pick, so "works but is not listed" reads
 * as "not supported".
 *
 * The fix
 * -------
 * Same shape as lkm4ctr's namespace work: the implementation already behaves
 * correctly and only its published view is wrong, so redirect the one function
 * that produces that view instead of fighting the data it reads.
 *
 * zcomp_available_show() is a global symbol in zram.ko (declared in zcomp.h,
 * called only from the comp_algorithm sysfs show handler), so it is resolvable
 * and hooking it covers every zram device.
 *
 * The hook is an inline branch, not a kprobe: a 4-byte b written over the first
 * instruction, with a trampoline holding the displaced instruction plus a
 * branch back. The trampoline is allocated next to the target because with
 * VA_BITS=39 the general vmalloc area sits tens of GB away from kernel text
 * (measured ~95GB on this device) and b only reaches +/-128MB. If no page near
 * enough is available, or the first instruction is PC-relative and would need
 * relocation, the module refuses to hook rather than guess -- a wrong
 * trampoline writes garbage into live kernel text.
 */

#include <linux/crypto.h>
#include <linux/init.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/types.h>
#include <linux/vmalloc.h>

#define ZL_NAME		"zram_list"
#define ZL_REACH	0x7000000UL	/* 112MB：b 的量程留 16MB 余量 */

/* 本项目可能提供的算法；只决定"列表里要不要多印一个名字" */
static const char * const zl_candidates[] = {
	"lz4k", "lz4kd", "lz4k_oplus", "lz4hc", "842",
	/*
	 * 厂商内核自带的树外算法也要列：本机 zstdp 已注册但不在 backends[]
	 * 里，属于"能用但看不见"。zl_candidates 只决定要不要补印名字，
	 * 是否真的存在仍由 crypto_has_comp() 判断，所以多写几个没副作用。
	 */
	"zstdp", "zstdn", "zstdn_o",
};

/* 内核自带的，用于在原函数不可用时兜底拼列表 */
static const char * const zl_builtin[] = {
	"lzo", "lzo-rle", "lz4", "lz4hc", "842", "zstd", "deflate",
};

typedef ssize_t (*zcomp_available_show_fn)(const char *comp, char *buf);
/* 内核自己的单条指令改写原语：处理页权限、icache 与 stop_machine */
typedef int (*zl_patch_insn_fn)(void *addr, u32 insn);
/* __vmalloc_node_range 没导出给模块，只能用 kallsyms 解析后调用 */
typedef void *(*zl_vmalloc_range_fn)(unsigned long size, unsigned long align,
				     unsigned long start, unsigned long end,
				     gfp_t gfp_mask, pgprot_t prot,
				     unsigned long vm_flags, int node,
				     const void *caller);

static zcomp_available_show_fn zl_orig;
static zl_patch_insn_fn zl_patch_insn;
static zl_vmalloc_range_fn zl_vmalloc_range;
static unsigned long zl_target;
static void *zl_tramp;
static u32 zl_saved;
static bool zl_hooked;

/*
 * 符号解析。
 *
 * 第一段用 kprobe 的 symbol_name 查找，绕开 kptr_restrict。但它只能找到
 * "可探测"的函数：aarch64_insn_patch_text_nosync 这类在 kprobe 黑名单里的
 * 就拿不到。
 *
 * 所以先只用 kprobe 拿到 kallsyms_lookup_name（它本身不在黑名单），后面所有
 * 符号都交给它——CONFIG_KALLSYMS_ALL=y 时它能查到内核里任何符号，包括模块。
 */
typedef unsigned long (*zl_kln_fn)(const char *name);

static zl_kln_fn zl_kln;

static unsigned long zl_lookup_probe(const char *name)
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

static unsigned long zl_lookup(const char *name)
{
	if (!zl_kln)
		zl_kln = (zl_kln_fn)zl_lookup_probe("kallsyms_lookup_name");
	if (zl_kln)
		return zl_kln(name);
	return zl_lookup_probe(name);
}

static bool zl_reachable(unsigned long from, unsigned long to);

/*
 * 在目标附近找一页可执行内存。
 *
 * vmap 树只跟踪它自己分配出去的区域，内核镜像的静态映射它并不知道，所以
 * 窗口必须先夹到镜像之外，否则分配器会把正在执行的代码页当空闲分出来。
 */
static void *zl_alloc_near(unsigned long near, size_t size)
{
	unsigned long img_s, img_e;
	void *mem;

	if (!near)
		return NULL;

	img_s = zl_lookup("_text");
	img_e = zl_lookup("_end");

	/*
	 * [WINDOW] 多窗口尝试。
	 *
	 * 只搜"夹取后剩下的一块"不够用：模块本身也分配在 vmalloc 区，镜像和
	 * 目标之间的那几十 MB 往往已经被别的模块占满，vmap 找不到空洞直接
	 * 返回 NULL。所以按多个距离、上下两个方向分别开窗。
	 */
	if (!zl_vmalloc_range) {
		zl_vmalloc_range = (zl_vmalloc_range_fn)zl_lookup("__vmalloc_node_range");
		if (!zl_vmalloc_range) {
			pr_warn(ZL_NAME ": __vmalloc_node_range unresolved' + BS + 'n");
			return NULL;
		}
	}

	{
		static const unsigned long edges[] = {
			SZ_4M, SZ_16M, SZ_64M, ZL_REACH - SZ_16M,
		};
		unsigned int k;

		for (k = 0; k < ARRAY_SIZE(edges); k++) {
			unsigned long span = edges[k];
			int dir;

			for (dir = 0; dir < 2; dir++) {
				unsigned long wlo, whi;

				if (dir == 0) {
					wlo = near > span ? near - span : 0;
					whi = near - SZ_4K;
				} else {
					wlo = near + SZ_4K;
					whi = near + span;
				}
				if (wlo >= whi)
					continue;

				/* 夹到镜像之外 */
				if (img_s && img_e && wlo < img_e && whi > img_s) {
					if (near >= img_e)
						wlo = img_e;
					else if (near <= img_s)
						whi = img_s;
					else
						continue;
					if (wlo >= whi)
						continue;
				}

				mem = zl_vmalloc_range(size, 1, wlo, whi,
						       GFP_KERNEL | __GFP_NOWARN,
						       PAGE_KERNEL_EXEC,
						       VM_FLUSH_RESET_PERMS,
						       NUMA_NO_NODE,
						       __builtin_return_address(0));
				if (mem) {
					if (zl_reachable(near, (unsigned long)mem))
						return mem;
					vfree(mem);
					mem = NULL;
				}
			}
		}
		pr_info(ZL_NAME ": no vmap hole in any window around %px' + BS + 'n",
			(void *)near);
		return NULL;
	}

	/* 拿到未必够得着，够不着就还回去 */
	if (!zl_reachable(near, (unsigned long)mem)) {
		vfree(mem);
		return NULL;
	}
	return mem;
}

/* 有符号距离判定，和 hk_branch_reachable 同义 */
static bool zl_reachable(unsigned long from, unsigned long to)
{
	long d = (long)to - (long)from;

	return d > -(long)ZL_REACH && d < (long)ZL_REACH;
}

/*
 * 只搬一条指令，且只接受与位置无关的。
 * adr/adrp/ldr 字面量/b/bl/cbz/tbz 都带 PC 相对偏移，搬走就错，拒绝。
 */
static bool zl_insn_relocatable(u32 insn)
{
	if ((insn & 0x1F000000) == 0x10000000)	/* adr / adrp */
		return false;
	if ((insn & 0x7C000000) == 0x14000000)	/* b / bl */
		return false;
	if ((insn & 0x7E000000) == 0x34000000)	/* cbz / cbnz */
		return false;
	if ((insn & 0x7E000000) == 0x36000000)	/* tbz / tbnz */
		return false;
	if ((insn & 0x3B000000) == 0x18000000)	/* ldr literal */
		return false;
	return true;
}

static u32 zl_enc_b(long off)
{
	return 0x14000000u | ((u32)(off >> 2) & 0x03FFFFFFu);
}

/* 名字是否已经在 buf 里（按 token 边界比较，避免 lz4 命中 lz4hc） */
static bool zl_has_token(const char *buf, size_t len, const char *name)
{
	size_t n = strlen(name), i;

	for (i = 0; i + n <= len; i++) {
		if (strncmp(buf + i, name, n))
			continue;
		if (i > 0 && buf[i - 1] != ' ' && buf[i - 1] != '[')
			continue;
		if (i + n < len && buf[i + n] != ' ' && buf[i + n] != ']')
			continue;
		return true;
	}
	return false;
}

static size_t zl_append(char *buf, size_t n, const char *name, bool active)
{
	int w = scnprintf(buf + n, PAGE_SIZE - n, "%s%s%s ",
			  active ? "[" : "", name, active ? "]" : "");

	return n + (size_t)w;
}

static size_t zl_build_builtin(const char *active, char *buf)
{
	size_t n = 0;
	int i;

	for (i = 0; i < (int)ARRAY_SIZE(zl_builtin); i++) {
		if (!crypto_has_comp(zl_builtin[i], 0, 0))
			continue;
		n = zl_append(buf, n, zl_builtin[i],
			      active && !strcmp(active, zl_builtin[i]));
		if (n >= PAGE_SIZE - 32)
			break;
	}
	return n;
}

/*
 * 把原函数印出来的列表再筛一遍：只留 crypto_has_comp() 认可的。
 *
 * 本机实测厂商 backends[] 里有 zstdn / zstdn_o，列得出来但根本没注册，
 * 用户照着选必然被 zram 拒绝。既然这个文件现在由我们生成，就不该继续
 * 展示不可用的名字。
 */
static size_t zl_filter(char *buf, size_t n, const char *active)
{
	char tmp[PAGE_SIZE];
	size_t out = 0, i = 0;

	while (i < n && out + 64 < sizeof(tmp)) {
		size_t s = i, e;
		char name[64];
		size_t len;
		bool bracketed = false;

		while (i < n && buf[i] == ' ')
			i++;
		s = i;
		while (i < n && buf[i] != ' ')
			i++;
		e = i;
		if (e <= s)
			continue;

		len = e - s;
		if (buf[s] == '[' && buf[e - 1] == ']') {
			bracketed = true;
			s++;
			len -= 2;
		}
		if (len >= sizeof(name))
			continue;
		memcpy(name, buf + s, len);
		name[len] = 0;

		if (crypto_has_comp(name, 0, 0)) {
			out += (size_t)scnprintf(tmp + out, sizeof(tmp) - out,
						 "%s%s%s ",
						 bracketed ? "[" : "", name,
						 bracketed ? "]" : "");
		}
	}

	memcpy(buf, tmp, out);
	return out;
}

static __nocfi ssize_t zl_show(const char *comp, char *buf)
{
	size_t n;
	int i;

	/* 原函数存在就用它——内置列表的格式和顺序保持内核原样 */
	if (zl_orig) {
		ssize_t r = zl_orig(comp, buf);

		n = r >= 0 ? (size_t)r : zl_build_builtin(comp, buf);
	} else {
		n = zl_build_builtin(comp, buf);
	}

	/* 去掉列着但没注册的幽灵条目 */
	n = zl_filter(buf, n, comp);

	for (i = 0; i < (int)ARRAY_SIZE(zl_candidates); i++) {
		const char *name = zl_candidates[i];

		if (!crypto_has_comp(name, 0, 0))
			continue;
		if (zl_has_token(buf, n, name))
			continue;
		if (n >= PAGE_SIZE - 32)
			break;
		n = zl_append(buf, n, name, comp && !strcmp(comp, name));
	}

	if (n >= PAGE_SIZE)
		n = PAGE_SIZE - 1;
	buf[n] = '\0';
	return (ssize_t)n;
}

static int zl_install(void)
{
	u32 first, patch;
	u32 *w;
	long off;
	int ret;

	zl_target = zl_lookup("zcomp_available_show");
	if (!zl_target) {
		pr_info(ZL_NAME ": zcomp_available_show not found; "
			"is zram loaded?\n");
		return -ENOENT;
	}

	zl_patch_insn = (zl_patch_insn_fn)zl_lookup("aarch64_insn_patch_text_nosync");
	if (!zl_patch_insn) {
		pr_warn(ZL_NAME ": aarch64_insn_patch_text_nosync unavailable\n");
		return -ENODATA;
	}

	zl_tramp = zl_alloc_near(zl_target, PAGE_SIZE);
	if (!zl_tramp) {
		pr_warn(ZL_NAME ": no executable page within reach of %px; "
			"refusing to hook\n", (void *)zl_target);
		return -ENOMEM;
	}

	ret = copy_from_kernel_nofault(&first, (void *)zl_target, sizeof(first));
	if (ret) {
		pr_warn(ZL_NAME ": cannot read the prologue\n");
		goto err;
	}
	if (!zl_insn_relocatable(first)) {
		pr_warn(ZL_NAME ": first instruction needs relocation; refusing\n");
		ret = -EOPNOTSUPP;
		goto err;
	}

	/*
	 * 近址页里放两段：
	 *
	 *   +0   被搬走的第 1 条指令
	 *   +4   ldr x17,#8 ; br x17 ; .quad (target+4)    <- zl_orig 指这里
	 *   +20  ldr x17,#8 ; br x17 ; .quad zl_show       <- 入口跳到这儿
	 *
	 * 为什么不能直接 b 到 zl_show：它在模块里，和 target 隔着几十 GB，
	 * 4 字节 b 够不到。所以入口只 b 到近址页（够得着），再由近址页用
	 * ldr+br 做绝对跳转。
	 */
	w = (u32 *)zl_tramp;
	w[0] = first;			/* 被搬走的指令 */
	w[1] = 0x58000051;		/* ldr x17, #8 */
	w[2] = 0xD61F0220;		/* br  x17     */
	((u64 *)&w[3])[0] = (u64)(zl_target + 4);
	w[5] = 0x58000051;		/* ldr x17, #8 */
	w[6] = 0xD61F0220;		/* br  x17     */
	((u64 *)&w[7])[0] = (u64)(unsigned long)zl_show;

	zl_orig = (zcomp_available_show_fn)zl_tramp;

	/* 入口：b (近址页 + 20) */
	off = (long)((unsigned long)zl_tramp + 20) - (long)zl_target;
	patch = zl_enc_b(off);
	ret = zl_patch_insn((void *)zl_target, patch);
	if (ret) {
		pr_warn(ZL_NAME ": patch failed %d\n", ret);
		zl_orig = NULL;
		goto err;
	}

	zl_saved = first;
	zl_hooked = true;
	pr_info(ZL_NAME ": hooked zcomp_available_show at %px -> %px\n",
		(void *)zl_target, zl_tramp);
	return 0;

err:
	vfree(zl_tramp);
	zl_tramp = NULL;
	return ret;
}

static void zl_remove(void)
{
	if (!zl_hooked)
		return;
	zl_hooked = false;

	/* 先把入口恢复成原指令，再释放 trampoline */
	if (zl_patch_insn && zl_target)
		zl_patch_insn((void *)zl_target, zl_saved);

	/* 入口已不指向 trampoline，等一次 RCU 保证没有在途调用 */
	synchronize_rcu();
	if (zl_tramp) {
		vfree(zl_tramp);
		zl_tramp = NULL;
	}
	zl_orig = NULL;
}

static int __init zl_init(void)
{
	int ret = zl_install();

	if (ret == -ENOENT)
		pr_info(ZL_NAME ": zram not loaded yet; insmod this again after zram\n");
	else if (ret)
		pr_info(ZL_NAME ": not hooked (%d); comp_algorithm stays as-is\n", ret);
	return 0;
}

static void __exit zl_exit(void)
{
	zl_remove();
}

module_init(zl_init);
module_exit(zl_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("list module-loaded compressors in zram's comp_algorithm");
MODULE_AUTHOR("misaka5202");