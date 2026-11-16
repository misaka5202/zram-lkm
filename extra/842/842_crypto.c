// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * 842 as a loadable crypto compressor, for zram on a kernel that trimmed it.
 *
 * Unlike lz4hc, this one carries the codec: vendor kernels usually turn off
 * CONFIG_CRYPTO_842 and CONFIG_842_COMPRESS together, so lib/842 is not built
 * into vmlinux at all and there is nothing to call into. The two lib/842
 * sources are compiled straight into this module instead.
 *
 * Upstream labels lib/842 a reference implementation and notes it is very slow
 * compared to the other software compressors. It exists here so the algorithm
 * name is available and selectable, not because it is a good default -- zram's
 * own Kconfig does not even offer 842 as a default backend.
 *
 * Registration follows crypto/842.c: the legacy CRYPTO_ALG_TYPE_COMPRESS path
 * for kernels up to 6.5 and crypto_register_scomp() for anything newer, since
 * the legacy type disappeared from the headers after 6.1. zram reaches it
 * through crypto_alloc_comp(), which never consults zram's own backends[] list
 * -- that list only decides what comp_algorithm prints.
 */

#include <linux/crypto.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/sw842.h>
#include <linux/version.h>

#include <crypto/internal/scompress.h>

/* 运行时符号解析：vendor 内核可能没导出下面这些辅助函数 */
#include "../compat/zram_symres.h"
/* 指针类型由 BTF 生成，不手写签名 —— 见 scripts/gen_symproto.py */
#include "../compat/zram_symproto.h"

static zr_t_crypto_register_scomp zr_register_scomp;
static zr_t_crypto_unregister_scomp zr_unregister_scomp;

/*
 * vendor 内核可能没导出 crypto_register_scomp()/crypto_unregister_scomp()，
 * 但函数本体在 kallsyms 里。重定向到运行时解析的指针。
 * 只在 init/exit 调用，不涉及压缩热路径。
 */
#define crypto_register_scomp(a)   zr_register_scomp(a)
#define crypto_unregister_scomp(a) zr_unregister_scomp(a)


struct crypto842_ctx {
	void *wmem;	/* working memory for compress */
};

static void *crypto842_alloc_ctx(struct crypto_scomp *tfm)
{
	void *ctx;

	ctx = kmalloc(SW842_MEM_COMPRESS, GFP_KERNEL);
	if (!ctx)
		return ERR_PTR(-ENOMEM);

	return ctx;
}

static void crypto842_free_ctx(struct crypto_scomp *tfm, void *ctx)
{
	kfree(ctx);
}

static int __crypto842_compress(struct crypto_tfm *tfm,
				const u8 *src, unsigned int slen,
				u8 *dst, unsigned int *dlen, void *wmem)
{
	int ret = sw842_compress(src, slen, dst, dlen, wmem);

	if (ret == -ENOSPC)
		return -EINVAL;
	return ret;
}

static int __crypto842_decompress(struct crypto_tfm *tfm,
				  const u8 *src, unsigned int slen,
				  u8 *dst, unsigned int *dlen)
{
	return sw842_decompress(src, slen, dst, dlen);
}

/* ---- 同步压缩接口（6.6+）---- */

static int crypto842_scompress(struct crypto_scomp *tfm,
			       const u8 *src, unsigned int slen,
			       u8 *dst, unsigned int *dlen, void *ctx)
{
	return __crypto842_compress(NULL, src, slen, dst, dlen, ctx);
}

static int crypto842_sdecompress(struct crypto_scomp *tfm,
				 const u8 *src, unsigned int slen,
				 u8 *dst, unsigned int *dlen, void *ctx)
{
	return __crypto842_decompress(NULL, src, slen, dst, dlen);
}

static struct scomp_alg scomp = {
	.alloc_ctx		= crypto842_alloc_ctx,
	.free_ctx		= crypto842_free_ctx,
	.compress		= crypto842_scompress,
	.decompress		= crypto842_sdecompress,
	.base			= {
		.cra_name	= "842",
		.cra_driver_name = "842-scomp",
		.cra_module	 = THIS_MODULE,
	}
};

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
/* ---- legacy 压缩接口（6.5 及更早）---- */

static int crypto842_init(struct crypto_tfm *tfm)
{
	struct crypto842_ctx *ctx = crypto_tfm_ctx(tfm);

	ctx->wmem = crypto842_alloc_ctx(NULL);
	if (IS_ERR(ctx->wmem))
		return -ENOMEM;

	return 0;
}

static void crypto842_exit(struct crypto_tfm *tfm)
{
	struct crypto842_ctx *ctx = crypto_tfm_ctx(tfm);

	crypto842_free_ctx(NULL, ctx->wmem);
}

static int crypto842_compress(struct crypto_tfm *tfm,
			      const u8 *src, unsigned int slen,
			      u8 *dst, unsigned int *dlen)
{
	struct crypto842_ctx *ctx = crypto_tfm_ctx(tfm);

	return __crypto842_compress(tfm, src, slen, dst, dlen, ctx->wmem);
}

static int crypto842_decompress(struct crypto_tfm *tfm,
				const u8 *src, unsigned int slen,
				u8 *dst, unsigned int *dlen)
{
	return __crypto842_decompress(tfm, src, slen, dst, dlen);
}

static struct crypto_alg alg = {
	.cra_name		= "842",
	.cra_driver_name	= "842-generic",
	.cra_flags		= CRYPTO_ALG_TYPE_COMPRESS,
	.cra_ctxsize		= sizeof(struct crypto842_ctx),
	.cra_module		= THIS_MODULE,
	.cra_init		= crypto842_init,
	.cra_exit		= crypto842_exit,
	.cra_u			= { .compress = {
	.coa_compress		= crypto842_compress,
	.coa_decompress		= crypto842_decompress } }
};
#endif /* < 6.6 */

static int __init __nocfi sw842_mod_init(void)
{

	int ret;
	ZR_REQUIRE(zr_register_scomp, crypto_register_scomp);
	ZR_REQUIRE(zr_unregister_scomp, crypto_unregister_scomp);

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	ret = crypto_register_alg(&alg);
	if (ret) {
		pr_err("[842] crypto_register_alg failed: %d\n", ret);
		return ret;
	}
#endif

	ret = crypto_register_scomp(&scomp);
	if (ret) {
		pr_err("[842] crypto_register_scomp failed: %d\n", ret);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
		crypto_unregister_alg(&alg);
#endif
		return ret;
	}

	pr_info("[842] registered\n");
	return 0;
}

static void __exit __nocfi sw842_mod_exit(void)
{
	crypto_unregister_scomp(&scomp);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	crypto_unregister_alg(&alg);
#endif
}

module_init(sw842_mod_init);
module_exit(sw842_mod_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("842 compressor for zram, carrying the lib/842 reference codec");
MODULE_AUTHOR("misaka5202");
MODULE_ALIAS_CRYPTO("842");