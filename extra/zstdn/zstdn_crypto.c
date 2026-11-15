// SPDX-License-Identifier: GPL-2.0-only
/*
 * zstdn / zstdn_o as loadable crypto compressors, for zram.
 *
 * What these names are
 * --------------------
 * They are OPPO/OnePlus module-provided compressors, not generic kernel ones.
 * The OnePlus 15 (sm8850) kernel source ships them in
 * vendor/oplus/kernel/mm/zstd_o/, where crypto_zstd.c registers "zstdn_o" and
 * the header comment explains the naming:
 *
 *     replace zstdn -> zstdn_o   n stands and oplus opt for newest
 *
 * and sets the one parameter that actually differs from plain zstd:
 *
 *     #define ZSTD_DEF_LEVEL	1
 *
 * The kernel's own zstd compressor runs at level 3. Level 1 trades ratio for
 * speed, which is the whole point on a swap device.
 *
 * Why this is a thin module
 * -------------------------
 * OPPO ships the zstd codec itself (27 files) because their module is built
 * out-of-tree. This kernel already has the codec built in and exports the
 * single-pass API -- zstd_get_params(), zstd_cctx_workspace_bound(),
 * zstd_init_cctx(), zstd_compress_cctx(), and the dctx counterparts -- so all
 * that is needed here is the crypto registration. Same shape as lz4hc.
 *
 * Both names are registered:
 *   zstdn    the legacy name OPPO's own zram backends[] array still lists
 *   zstdn_o  the name their current module actually registers
 *
 * Registering both is deliberate: OPPO's list and OPPO's registration have
 * drifted apart (`backends[]` says zstdn, the module says zstdn_o), so a device
 * running their firmware can want either. With both present, whichever name
 * zram is asked for resolves.
 *
 * Two registration APIs have to be covered. Up to 6.1 zram's
 * crypto_alloc_comp() asks for CRYPTO_ALG_TYPE_COMPRESS, published by
 * crypto_register_alg() with coa_compress. Newer kernels dropped that legacy
 * type and resolve synchronous compression algorithms published by
 * crypto_register_scomp(). Upstream crypto/zstd.c registers both; this does the
 * same, with the legacy half compiled out where it no longer exists.
 *
 * This is not OPPO's codec. It is the kernel's, driven at level 1. Compression
 * ratios will differ slightly from OPPO's build because theirs is a different
 * zstd release, but the algorithm and level are the same.
 */

#include <linux/crypto.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/version.h>
#include <linux/vmalloc.h>
#include <linux/zstd.h>

#include <crypto/internal/scompress.h>

/* 与 OPPO zstdn_o 的 ZSTD_DEF_LEVEL 一致；内核自带 zstd 用 3 */
#define ZSTDN_DEF_LEVEL		1
/*
 * 有效级别范围。必须用 zstd_min_clevel()/zstd_max_clevel()：
 * 库自己的 ZSTD_minCLevel()/ZSTD_maxCLevel() 没有 EXPORT_SYMBOL，用了会在
 * insmod 时报 unknown symbol —— 正是这类问题。
 */
#define ZSTDN_MIN_LEVEL		zstd_min_clevel()
#define ZSTDN_MAX_LEVEL		zstd_max_clevel()

/*
 * 级别做成只读参数：zram 里换成这个算法之后，行为应当稳定可预期，
 * 不应该被运行期随手改掉导致前后压缩率不一致。
 */
static int zstdn_level = ZSTDN_DEF_LEVEL;
module_param_named(zstdn_level, zstdn_level, int, 0444);
MODULE_PARM_DESC(zstdn_level,
		 "zstd compression level for zstdn/zstdn_o (default 1, OPPO zstdn_o uses 1)");

struct zstdn_ctx {
	zstd_cctx	*cctx;
	zstd_dctx	*dctx;
	void		*cwksp;
	void		*dwksp;
};

static void zstdn_ctx_free(struct zstdn_ctx *ctx)
{
	if (!ctx)
		return;
	vfree(ctx->cwksp);
	vfree(ctx->dwksp);
	kfree(ctx);
}

static struct zstdn_ctx *zstdn_ctx_alloc(void)
{
	struct zstdn_ctx *ctx;
	zstd_parameters params;
	size_t csize, dsize;

	params = zstd_get_params(zstdn_level, 0);
	csize = zstd_cctx_workspace_bound(&params.cParams);
	dsize = zstd_dctx_workspace_bound();

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return ERR_PTR(-ENOMEM);

	ctx->cwksp = vmalloc(csize);
	ctx->dwksp = vmalloc(dsize);
	if (!ctx->cwksp || !ctx->dwksp) {
		zstdn_ctx_free(ctx);
		return ERR_PTR(-ENOMEM);
	}

	ctx->cctx = zstd_init_cctx(ctx->cwksp, csize);
	ctx->dctx = zstd_init_dctx(ctx->dwksp, dsize);
	if (!ctx->cctx || !ctx->dctx) {
		zstdn_ctx_free(ctx);
		return ERR_PTR(-ENOMEM);
	}
	return ctx;
}

/*
 * 约定与内核其它 compressor 一致：*dlen 进来是目标缓冲容量，出去是实际长度。
 */
static int __zstdn_compress(const u8 *src, unsigned int slen,
			    u8 *dst, unsigned int *dlen, void *ctx)
{
	struct zstdn_ctx *c = ctx;
	zstd_parameters params;
	size_t out;

	if (!c || !c->cctx)
		return -EINVAL;

	/*
	 * 用本次的实际源长度重算参数：levels 会随 srcSize 影响窗口大小，
	 * 固定用 0 会在大页上白白多占内存。
	 */
	params = zstd_get_params(zstdn_level, slen);
	out = zstd_compress_cctx(c->cctx, dst, *dlen, src, slen, &params);
	if (zstd_is_error(out))
		return -EINVAL;

	*dlen = (unsigned int)out;
	return 0;
}

static int __zstdn_decompress(const u8 *src, unsigned int slen,
			      u8 *dst, unsigned int *dlen, void *ctx)
{
	struct zstdn_ctx *c = ctx;
	size_t out;

	if (!c || !c->dctx)
		return -EINVAL;

	out = zstd_decompress_dctx(c->dctx, dst, *dlen, src, slen);
	if (zstd_is_error(out))
		return -EINVAL;

	*dlen = (unsigned int)out;
	return 0;
}

/* ---- 同步压缩接口（crypto_register_scomp），6.6+ 走这条 ---- */

static void *zstdn_alloc_ctx(struct crypto_scomp *tfm)
{
	return zstdn_ctx_alloc();
}

static void zstdn_scomp_free_ctx(struct crypto_scomp *tfm, void *ctx)
{
	zstdn_ctx_free(ctx);
}

static int zstdn_scompress(struct crypto_scomp *tfm, const u8 *src,
			   unsigned int slen, u8 *dst, unsigned int *dlen,
			   void *ctx)
{
	return __zstdn_compress(src, slen, dst, dlen, ctx);
}

static int zstdn_sdecompress(struct crypto_scomp *tfm, const u8 *src,
			     unsigned int slen, u8 *dst, unsigned int *dlen,
			     void *ctx)
{
	return __zstdn_decompress(src, slen, dst, dlen, ctx);
}

static struct scomp_alg scomp_zstdn = {
	.alloc_ctx		= zstdn_alloc_ctx,
	.free_ctx		= zstdn_scomp_free_ctx,
	.compress		= zstdn_scompress,
	.decompress		= zstdn_sdecompress,
	.base			= {
		.cra_name	= "zstdn",
		.cra_driver_name = "zstdn-scomp",
		.cra_module	 = THIS_MODULE,
	}
};

static struct scomp_alg scomp_zstdn_o = {
	.alloc_ctx		= zstdn_alloc_ctx,
	.free_ctx		= zstdn_scomp_free_ctx,
	.compress		= zstdn_scompress,
	.decompress		= zstdn_sdecompress,
	.base			= {
		.cra_name	= "zstdn_o",
		.cra_driver_name = "zstdn_o-scomp",
		.cra_module	 = THIS_MODULE,
	}
};

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
/* ---- legacy 压缩接口（CRYPTO_ALG_TYPE_COMPRESS），6.5 及更早需要 ---- */

static int zstdn_cra_init(struct crypto_tfm *tfm)
{
	struct zstdn_ctx **slot = crypto_tfm_ctx(tfm);
	struct zstdn_ctx *ctx;

	ctx = zstdn_ctx_alloc();
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	*slot = ctx;
	return 0;
}

static void zstdn_cra_exit(struct crypto_tfm *tfm)
{
	struct zstdn_ctx **slot = crypto_tfm_ctx(tfm);

	zstdn_ctx_free(*slot);
	*slot = NULL;
}

static int zstdn_compress(struct crypto_tfm *tfm,
			  const u8 *src, unsigned int slen,
			  u8 *dst, unsigned int *dlen)
{
	struct zstdn_ctx **slot = crypto_tfm_ctx(tfm);

	return __zstdn_compress(src, slen, dst, dlen, *slot);
}

static int zstdn_decompress(struct crypto_tfm *tfm,
			    const u8 *src, unsigned int slen,
			    u8 *dst, unsigned int *dlen)
{
	struct zstdn_ctx **slot = crypto_tfm_ctx(tfm);

	return __zstdn_decompress(src, slen, dst, dlen, *slot);
}

#define ZSTDN_LEGACY_ALG(_name, _driver)				\
static struct crypto_alg _name = {					\
	.cra_name		= _driver,				\
	.cra_driver_name	= _driver "-generic",			\
	.cra_flags		= CRYPTO_ALG_TYPE_COMPRESS,		\
	.cra_ctxsize		= sizeof(struct zstdn_ctx *),		\
	.cra_module		= THIS_MODULE,				\
	.cra_init		= zstdn_cra_init,			\
	.cra_exit		= zstdn_cra_exit,			\
	.cra_u			= { .compress = {			\
		.coa_compress	= zstdn_compress,			\
		.coa_decompress	= zstdn_decompress,			\
	} }								\
}

ZSTDN_LEGACY_ALG(alg_zstdn, "zstdn");
ZSTDN_LEGACY_ALG(alg_zstdn_o, "zstdn_o");
#endif /* < 6.6 */

static int __init zstdn_mod_init(void)
{
	int ret;

	/*
	 * 级别越界不是"自动收敛"就是未定义行为。与其让 zram 收进一堆压不动
	 * 的页，不如加载时就失败，把问题暴露在 insmod 那一步。
	 */
	if (zstdn_level < ZSTDN_MIN_LEVEL || zstdn_level > ZSTDN_MAX_LEVEL) {
		pr_err("[zstdn] level %d out of range [%d, %d]\n",
		       zstdn_level, ZSTDN_MIN_LEVEL, ZSTDN_MAX_LEVEL);
		return -EINVAL;
	}

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	ret = crypto_register_alg(&alg_zstdn);
	if (ret) {
		pr_err("[zstdn] register zstdn (legacy) failed: %d\n", ret);
		return ret;
	}
	ret = crypto_register_alg(&alg_zstdn_o);
	if (ret) {
		pr_err("[zstdn] register zstdn_o (legacy) failed: %d\n", ret);
		crypto_unregister_alg(&alg_zstdn);
		return ret;
	}
#endif

	ret = crypto_register_scomp(&scomp_zstdn);
	if (ret) {
		pr_err("[zstdn] register zstdn (scomp) failed: %d\n", ret);
		goto err_legacy_o;
	}

	ret = crypto_register_scomp(&scomp_zstdn_o);
	if (ret) {
		pr_err("[zstdn] register zstdn_o (scomp) failed: %d\n", ret);
		crypto_unregister_scomp(&scomp_zstdn);
		goto err_legacy_o;
	}

	pr_info("[zstdn] registered zstdn + zstdn_o at zstd level %d\n", zstdn_level);
	return 0;

err_legacy_o:
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	crypto_unregister_alg(&alg_zstdn_o);
	crypto_unregister_alg(&alg_zstdn);
#endif
	return ret;
}

static void __exit zstdn_mod_exit(void)
{
	crypto_unregister_scomp(&scomp_zstdn_o);
	crypto_unregister_scomp(&scomp_zstdn);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	crypto_unregister_alg(&alg_zstdn_o);
	crypto_unregister_alg(&alg_zstdn);
#endif
}

module_init(zstdn_mod_init);
module_exit(zstdn_mod_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("zstdn / zstdn_o compressors for zram (OPPO's names, kernel zstd at level 1)");
MODULE_AUTHOR("misaka5202");
MODULE_ALIAS_CRYPTO("zstdn");
MODULE_ALIAS_CRYPTO("zstdn_o");