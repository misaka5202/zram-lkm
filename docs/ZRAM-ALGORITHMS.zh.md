# zram 到底有多少种压缩算法？

一句话：**crypto API 认识多少个，就有多少个** —— zram 自己没有强制名单。

## 为什么没有固定数字

`drivers/block/zram/zcomp.c`：

```c
bool zcomp_available_algorithm(const char *comp)
{
	return crypto_has_comp(comp, 0, 0) == 1;
}
```

整个校验就这一句。往 `/sys/block/zramN/comp_algorithm` 写名字时，zram 只是
问 crypto API「有没有注册这个 compression 算法」，有就接受。

同文件里的 `backends[]` 数组很容易被当成白名单：

```c
static const char * const backends[] = {
#if IS_ENABLED(CONFIG_CRYPTO_LZO)
	"lzo", "lzo-rle",
#endif
#if IS_ENABLED(CONFIG_CRYPTO_LZ4)
	"lz4",
#endif
#if IS_ENABLED(CONFIG_CRYPTO_LZ4HC)
	"lz4hc",
#endif
#if IS_ENABLED(CONFIG_CRYPTO_842)
	"842",
#endif
#if IS_ENABLED(CONFIG_CRYPTO_ZSTD)
	"zstd",
#endif
};
```

它只被 `zcomp_available_show()` 读，作用是打印 `comp_algorithm` 的内容并用
方括号标出当前算法。不在这张表里的算法**照样能用**，只是永远不出现在那个
文件里——本项目提供的每一个算法都是这种情况。`deflate` 在很多厂商内核里是
开着的，却也从不显示，原因相同。

## 上游自带的 7 个

`crypto/` 下 zram 能用的 `cra_name` 共七个：

| # | `cra_name` | `cra_driver_name` | 配置开关 |
|---|---|---|---|
| 1 | `842` | `842-generic` | `CONFIG_CRYPTO_842` |
| 2 | `deflate` | `deflate-generic` | `CONFIG_CRYPTO_DEFLATE` |
| 3 | `lz4` | `lz4-generic` | `CONFIG_CRYPTO_LZ4` |
| 4 | `lz4hc` | `lz4hc-generic` | `CONFIG_CRYPTO_LZ4HC` |
| 5 | `lzo` | `lzo-generic` | `CONFIG_CRYPTO_LZO` |
| 6 | `lzo-rle` | `lzo-rle-generic` | `CONFIG_CRYPTO_LZO` |
| 7 | `zstd` | `zstd-generic` | `CONFIG_CRYPTO_ZSTD` |

除此之外要么是树外编解码器（lz4k 系列，以及几十种厂商变体），要么还没人包过。

## 本项目新增的

| 模块 | 算法名 | 需要内核导出编解码器吗 |
|---|---|---|
| `lz4k` | `lz4k` | 不需要，编解码器编进模块里 |
| `lz4kd` | `lz4kd` | 不需要，同上 |
| `lz4k_oplus` | `lz4k_oplus` | 不需要，同上 |
| `lz4hc` | `lz4hc` | 需要，复用 `LZ4_compress_HC` / `LZ4_decompress_safe` |

`lz4hc` 是有意思的那个。厂商内核通常把 LZ4HC 编解码器编进去
（`CONFIG_LZ4HC_COMPRESS=y`），却把 crypto 注册那一层裁掉
（`# CONFIG_CRYPTO_LZ4HC is not set`），因为 GKI ABI 检查卡的正是注册。
而那两个编解码函数是 `EXPORT_SYMBOL` 的，所以模块只需要注册一个
`crypto_alg`——不用搬编解码器，几十行代码，产物几百 KB 而不是几 MB。

这和 user namespace 是同一个局面：**实现体已经在核心里，被编掉的只是把它
公布出来的那层胶水。**

## 怎么查自己的设备

```sh
# 内核到底暴露了哪些
grep -E 'name|driver' /proc/crypto | grep -i comp

# 更直接：拿名字去试
echo lz4hc > /sys/block/zram0/comp_algorithm && echo 可以用
```

`/proc/crypto` 列出所有已注册的变换及其类型，`type : compression` 的就是
zram 候选。

## 该选哪个

压缩率和速度取决于设备和负载，所以本项目给的是 `scripts/zram-bench.sh`，
而不是一张拍脑袋的对比表。ARM64 上大致从快到高压缩率：
`lz4` → `lz4k` → `lz4hc`（`lz4hc_level` 3-16）→ `zstd`。
`lzo-rle` 的压缩率接近 `lz4k`、CPU 更低。页之间相似度高时
（zram swap 的常见情况）值得试 `lz4kd` 和 `lz4k_oplus`。
