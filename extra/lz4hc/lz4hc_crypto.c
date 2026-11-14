// SPDX-License-Identifier: GPL-2.0-only
/*
 * lz4hc as a loadable crypto compressor, for zram on a vendor kernel that
 * built the LZ4HC codec but not its crypto registration.
 *
 * The codec lives in lib/lz4/lz4hc_compress.c and lib/lz4/lz4_decompress.c,
 * which stay built into vmlinux (CONFIG_LZ4HC_COMPRESS / CONFIG_LZ4_DECOMPRESS)
 * and export LZ4_compress_HC() and LZ4_decompress_safe(). So this module is the
 * registration alone, not a codec copy -- which is why it is a few dozen lines
 * instead of the several thousand lz4k needs.
 *
 * zram reaches it the same way it reaches any other compressor: writing the
 * name to /sys/block/zramN/comp_algorithm calls crypto_alloc_comp(), which
 * resolves through the crypto API and never consults zram's own backends[]
 * list. backends[] only decides what comp_algorithm prints.
 *
 * Two registration APIs have to be covered. Up to 6.1 zram's
 * crypto_alloc_comp() asks for CRYPTO_ALG_TYPE_COMPRESS, which is what
 * crypto_register_alg() with coa_compress publishes. Newer kernels dropped that
 * legacy type (crypto_tfm_ctx and the coa_ callbacks are gone from the headers),
 * and crypto_alloc_comp() resolves synchronous compression algorithms instead,
 * published by crypto_register_scomp(). Upstream crypto/lz4hc.c registers both;
 * this does the same, with the legacy half compiled out where it no longer
 * exists.
 */

#include <linux/crypto.h>
#include <linux/init.h>
#include <linux/lz4.h>
#include <linux/module.h>
#include <linux/version.h>
#include <linux/vmalloc.h>

#include <crypto/internal/scompress.h>

/*
 * LZ4HC 的压缩级别决定压缩率/速度取舍：3 最快、16 压缩率最高，内核默认 9。
 * 想在同样内存占用下多榨一点压缩率就 insmod lz4hc_level=16；想少占 CPU 就
 * 调低。只读参数，避免运行期被随手改掉导致 zram 行为前后不一致。
 */
static int lz4hc_level = LZ4HC_DEFAULT_CLEVEL;
module_param_named(lz4hc_level, lz4hc_level, int, 0444);
MODULE_PARM_DESC(lz4hc_level,
		 "LZ4HC compression level, 3-16 (default 9)");

static void *lz4hc_alloc_ctx(struct crypto_scomp *tfm)
{
	void *ctx;

	ctx = vmalloc(LZ4HC_MEM_COMPRESS);
	if (!ctx)
		return ERR_PTR(-ENOMEM);

	return ctx;
}

static void lz4hc_free_ctx(struct crypto_scomp *tfm, void *ctx)
{
	vfree(ctx);
}

/*
 * 来源内核的写法：*dlen 进来是目标缓冲区容量，出去是实际输出长度。
 * LZ4_compress_HC() 返回 0 表示目标装不下。
 */
static int __lz4hc_compress_crypto(const u8 *src, unsigned int slen,
				   u8 *dst, unsigned int *dlen, void *ctx)
{
	int out_len;

	/*
	 * 级别夹到内核头文件声明的范围。超出范围不是"自动收敛"就是未定义，
	 * 与其让 zram 收进一堆压不动的页，不如直接失败，让写 comp_algorithm
	 * 的那一步报错。
	 */
	if (lz4hc_level < LZ4HC_MIN_CLEVEL || lz4hc_level > LZ4HC_MAX_CLEVEL)
		return -EINVAL;

	out_len = LZ4_compress_HC(src, dst, slen, *dlen, lz4hc_level, ctx);
	if (!out_len)
		return -EINVAL;

	*dlen = out_len;
	return 0;
}

static int __lz4hc_decompress_crypto(const u8 *src, unsigned int slen,
				     u8 *dst, unsigned int *dlen, void *ctx)
{
	int out_len = LZ4_decompress_safe(src, dst, slen, *dlen);

	if (out_len < 0)
		return -EINVAL;

	*dlen = out_len;
	return 0;
}

/* ---- 同步压缩接口（crypto_register_scomp），6.6+ 走这条 ---- */

static int lz4hc_scompress(struct crypto_scomp *tfm, const u8 *src,
			   unsigned int slen, u8 *dst, unsigned int *dlen,
			   void *ctx)
{
	return __lz4hc_compress_crypto(src, slen, dst, dlen, ctx);
}

static int lz4hc_sdecompress(struct crypto_scomp *tfm, const u8 *src,
			     unsigned int slen, u8 *dst, unsigned int *dlen,
			     void *ctx)
{
	return __lz4hc_decompress_crypto(src, slen, dst, dlen, NULL);
}

static struct scomp_alg scomp = {
	.alloc_ctx		= lz4hc_alloc_ctx,
	.free_ctx		= lz4hc_free_ctx,
	.compress		= lz4hc_scompress,
	.decompress		= lz4hc_sdecompress,
	.base			= {
		.cra_name	= "lz4hc",
		.cra_driver_name = "lz4hc-scomp",
		.cra_module	 = THIS_MODULE,
	}
};

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
/* ---- legacy 压缩接口（CRYPTO_ALG_TYPE_COMPRESS），6.5 及更早需要 ---- */

struct lz4hc_ctx {
	void *lz4hc_comp_mem;
};

static int lz4hc_init(struct crypto_tfm *tfm)
{
	struct lz4hc_ctx *ctx = crypto_tfm_ctx(tfm);

	ctx->lz4hc_comp_mem = lz4hc_alloc_ctx(NULL);
	if (IS_ERR(ctx->lz4hc_comp_mem))
		return -ENOMEM;

	return 0;
}

static void lz4hc_exit(struct crypto_tfm *tfm)
{
	struct lz4hc_ctx *ctx = crypto_tfm_ctx(tfm);

	lz4hc_free_ctx(NULL, ctx->lz4hc_comp_mem);
}

static int lz4hc_compress_crypto(struct crypto_tfm *tfm, const u8 *src,
				 unsigned int slen, u8 *dst,
				 unsigned int *dlen)
{
	struct lz4hc_ctx *ctx = crypto_tfm_ctx(tfm);

	return __lz4hc_compress_crypto(src, slen, dst, dlen,
				       ctx->lz4hc_comp_mem);
}

static int lz4hc_decompress_crypto(struct crypto_tfm *tfm, const u8 *src,
				   unsigned int slen, u8 *dst,
				   unsigned int *dlen)
{
	return __lz4hc_decompress_crypto(src, slen, dst, dlen, NULL);
}

static struct crypto_alg alg_lz4hc = {
	.cra_name		= "lz4hc",
	.cra_driver_name	= "lz4hc-generic",
	.cra_flags		= CRYPTO_ALG_TYPE_COMPRESS,
	.cra_ctxsize		= sizeof(struct lz4hc_ctx),
	.cra_module		= THIS_MODULE,
	.cra_init		= lz4hc_init,
	.cra_exit		= lz4hc_exit,
	.cra_u			= { .compress = {
	.coa_compress		= lz4hc_compress_crypto,
	.coa_decompress		= lz4hc_decompress_crypto } }
};
#endif /* < 6.6 */

static int __init lz4hc_mod_init(void)
{
	int ret;

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	ret = crypto_register_alg(&alg_lz4hc);
	if (ret) {
		pr_err("[lz4hc] crypto_register_alg failed: %d\n", ret);
		return ret;
	}
#endif

	ret = crypto_register_scomp(&scomp);
	if (ret) {
		pr_err("[lz4hc] crypto_register_scomp failed: %d\n", ret);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
		crypto_unregister_alg(&alg_lz4hc);
#endif
		return ret;
	}

	pr_info("[lz4hc] registered, level=%d\n", lz4hc_level);
	return 0;
}

static void __exit lz4hc_mod_exit(void)
{
	crypto_unregister_scomp(&scomp);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
	crypto_unregister_alg(&alg_lz4hc);
#endif
}

module_init(lz4hc_mod_init);
module_exit(lz4hc_mod_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("LZ4HC compressor for zram, over the kernel's built-in LZ4HC codec");
MODULE_AUTHOR("misaka5202");
MODULE_ALIAS_CRYPTO("lz4hc");