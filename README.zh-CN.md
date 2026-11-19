# ZRAM LKM

**在原始 Android GKI 内核上以可加载模块的方式扩展 ZRAM 压缩算法 —— 不重编内核、不刷 boot。**

[English](README.md) · [Releases](../../releases/latest)

---

厂商内核为了通过 GKI ABI 检查，通常只保留 `lzo-rle` 一种 ZRAM 压缩算法，
其余算法（尤其 LZ4K 系列）在编译期就被裁掉了。本项目把这些算法做成 `.ko`，
`insmod` 即可用，甚至在写 `comp_algorithm` 时会**自动按需加载**。

## 项目状态

**还没有正式版本。** 这里发布的每个 tag 都是 GitHub **pre-release（预览版）**。
这些模块验证到"七个 KMI 都能编、在一个真机上能加载能压"；还没有跨厂商回归，
所以请当成"试一试用、有问题反馈"的构建。

| | |
|---|---|
| CI 做什么 | 编译全部 KMI，**不发布**；`.ko` 只作为 Actions artifact 保留 |
| Release 做什么 | 只在打 tag（`vX.Y.Z`）时运行，发布**预览版** |
| 去哪反馈 | [新建 issue](https://github.com/misaka5202/zram-lkm/issues/new/choose) |

## 包含的算法

| 模块 | 算法名 | 来源 | 相对 lzo-rle |
|------|--------|------|--------------|
| `lz4k` | `lz4k` | 华为 | 压缩率更高，速度接近 LZ4 |
| `lz4kd` | `lz4kd` | 华为 | LZ4K 的 delta 变体，利用页间相似性 |
| `lz4k_oplus` | `lz4k_oplus` | OPPO | LZ4K 的 OPPO 分支实现 |
| `lz4hc` | `lz4hc` | 上游 LZ4 | LZ4 系里压缩率最高；`lz4hc_level=` 可调 3-16 |
| `842` | `842` | IBM | 自带 lib/842 参考实现；厂商内核通常把 `CONFIG_CRYPTO_842` 和编解码器一起裁掉。速度很慢，只为补齐算法，不作默认 |
| `zstdn` / `zstdn_o` | `zstdn`, `zstdn_o` | OPPO | 一加把它做成 `oplus_bsp_zstdn`；和 `zstd` 同一套编解码，但跑在 level 1（`ZSTD_DEF_LEVEL 1`）。薄模块，复用内核 zstd，不复制编解码器 |

`lz4hc` 是**只做注册**的模块：它直接调用内核已经导出的 `LZ4_compress_HC` /
`LZ4_decompress_safe`，自己不携带编解码器。厂商内核通常把编解码器编了
（`CONFIG_LZ4HC_COMPRESS=y`），只把 crypto 注册那一层裁掉。

**一共有多少种算法？** 上游有 7 个 zram 能用的算法名，而 zram 本身一个都不
强制——完整清单、为什么 `comp_algorithm` 只显示其中一部分、以及怎么查设备，
见 [ZRAM-ALGORITHMS.zh-CN.md](docs/ZRAM-ALGORITHMS.zh-CN.md)。

## 为什么能做成模块

关键在**压缩算法不是内核私有结构，而是 crypto 算法名空间的一部分**：

```
zram 写 comp_algorithm
      ↓
crypto_alloc_comp("lz4k")
      ↓
内核里查不到该算法 → request_module("crypto-lz4k")
      ↓
modprobe 找到 lz4k.ko 的 MODULE_ALIAS_CRYPTO("lz4k")
      ↓
模块加载 → crypto_register_alg() 注册 → zram 拿到算法
```

所以：

- `CONFIG_CRYPTO_*` 只决定**内核自带**哪些算法，不影响能否**新增**
- 模块带 `MODULE_ALIAS_CRYPTO(...)` 就会被 `request_module` 自动拉起，
  不需要手工 `insmod`
- 算法之间互不依赖，一个编不出来不影响其他

对比一下**做不到**的情形：`CONFIG_ZRAM_WRITEBACK`、`CONFIG_CFS_BANDWIDTH`
这类是**代码路径级**的编译开关，被 `#ifdef` 整段删除，模块没有可挂的点。
压缩算法不属于这一类。

## 厂商没导出的符号

有些厂商内核把函数留在 `kallsyms` 里，却没有导出。模块静态引用这种符号会
直接 `Unknown symbol` 装不上 —— 哪怕代码本体就在镜像里。

在 Qualcomm `SM7675 / 6.1.138` 上，六个算法模块里有三个是这种情况：

| 模块 | 运行时需要解析的符号 |
|---|---|
| `842` | `crypto_register_scomp`、`crypto_unregister_scomp` |
| `lz4hc` | 上面两个，加 `LZ4_compress_HC`、`LZ4_decompress_safe` |
| `zstdn` | 上面两个，加十个 `zstd_*()` 入口 |

做法改成 init 时解析地址。`extra/compat/zram_symres.h` 优先走
[**KallRecon**](https://github.com/Dere3046/KallRecon)（`extra/kallrecon/`，
从上游 `lib/` 逐字节 vendoring）：直接解析内核的 kallsyms 表，不依赖 kprobe、
不受 `kptr_restrict` 影响，连 kprobe 黑名单里的目标也能查到。KallRecon 布局
探测失败时退回旧路径 —— 用 kprobe 取 `kallsyms_lookup_name()` 再逐个查。
调用走函数指针，凡是这样调用的函数都标了 `__nocfi` —— `CONFIG_CFI_CLANG`
会校验间接调用目标，不标就被拒。

**代价是什么。** 查找只在 `insmod` 时做一次。实测加载耗时跟符号数量无关：
`lz4k`（0 个）、`lz4hc`（4 个）、`zstdn`（12 个）都落在 50–90 ms 这一档，
那是模块加载器本身的成本。运行期唯一的差别是每次编解码调用多一层间接跳转，
而且只在 `lz4hc` 和 `zstdn` 上 —— `842` 自带编解码器，热路径一次都没有。

### 和「内核内置」版本的实测对比

「每次调用多一层间接跳转」只是推理。下面是实测：刷了一颗把这些算法全部编进
内核的 6.1，于是同一台设备上同一个算法存在两份 —— 一份是内核代码直接调用，
一份是模块经解析出来的指针调用。

Redmi Pad `2410CRP4CG` / `SM7675` / `6.1.138-android14-11-g5929004f86ffc-…-4k`。
60 MB 真实 `.so`，每个样本新建一个 zram 设备，取 9–13 个样本的中位数，原生和
模块交替测量以抵消漂移：

| 算法 | 内核内置 | 模块 | 差 |
|---|---|---|---|
| `lz4hc` | 574 ms | 568 ms | −1.0% |
| `lz4k` | 207 ms | 215 ms | +3.9% |
| `lz4kd` | 206 ms | 200 ms | −2.9% |
| `lz4k_oplus` | 233 ms | 236 ms | +1.3% |
| `lzo` —— 对照组，两行都是内核代码 | 228 ms | 229 ms | +0.4% |
| `zstd` —— 对照组 | 533 ms | 525 ms | −1.5% |
| `842` —— 对照组，模块那份永远选不上 | 839 ms | 841 ms | +0.2% |

三个对照组在物理上不可能有差别，它们把噪声底定在 ±1.5%。单个样本的离散度是
3–10%，九个样本的中位数差 4% 算不上信号；而且四个算法的正负号在来回翻 ——
这就是「没有差别」的样子。两种配置下压缩后字节数完全相同（lz4hc 都是
38,095,631），说明跑的确实是同一份编解码器。

**一条测量教训，代价是一个小时。** 第一轮测出来 `lz4hc` 模块版慢 5%，而且三趟
都稳定复现。那是错的：`insmod` 之后的第一个样本必然偏慢 —— 模块的代码段刚映射
进来，i-cache 和分支预测器都是冷的。先热身一次、把这个样本丢掉，差距就完全
消失了。**交替测量救不了这个**，因为冷样本是跟着每一次 `insmod` 走的。

### 如果内核本来就有这些算法

模块注册的算法名和内核完全一样，最后 `zram` 用哪一份取决于 `cra_priority`：

| 算法 | 优先级 | 谁生效 |
|---|---|---|
| `lz4k` `lz4kd` `lz4k_oplus` `lz4hc` | 内核 0，模块 0 | 后注册的那份 —— 也就是 `insmod` 之后的模块。两边同一份编解码器 |
| `842` | **内核 100**，模块 0 | 永远是内核。模块装上、注册成功，然后一次都不会被调用 |
| `zstdn` `zstdn_o` | OPPO 私有，一般内核都没有 | 只有模块这一个来源 |

`842` 这条是实测的：在上面那颗内核上让一个 zram 设备用着 `842`，模块引用计数
仍然是 0，`rmmod` 直接成功。它无害 —— 模块就在那儿挂着 —— 但如果有人以为装上
就能接管，那是不会发生的。把模块的 `cra_priority` 抬到内核之上可以翻过来；
不过两边跑的是同一份 `lib/842`，翻过来也没有意义。

实际结论：**在一颗把十个算法全部编进去的内核上，这个模块唯一还提供的是
`zstdn` / `zstdn_o`**。其余的只是重复，不快也不慢。

**前提是什么。** 需要 `CONFIG_KALLSYMS_ALL`。如果函数在内核里压根不存在，
什么办法都没有；模块会在 init 失败并报出是哪个符号。

**怎么看自己的内核缺什么。** 构建时会把每个模块的未定义符号写进
`ko/symcheck-<kmi>.txt`；「操作」按钮拿它比对 `/proc/kallsyms` 里的
`__ksymtab_` 条目，直接列出本内核没导出的那几个 —— 报 issue 时能说清缺什么，
而不是只贴一句 `Unknown symbol`。

**指针类型从哪来。** `extra/compat/zram_symproto.h` 由
`scripts/gen_symproto.py` 从内核自己的 BTF 生成 —— 那是运行中镜像对自己类型的
描述，不是谁手打的签名：

```sh
python3 scripts/gen_symproto.py --btf vmlinux.btf \
    --symbols crypto_register_scomp crypto_unregister_scomp \
              LZ4_compress_HC LZ4_decompress_safe \
    --out extra/compat/zram_symproto.h
```

`--from-ko` 反过来，从编译好的模块推它需要哪些符号；`--verify` 重新生成并与
已提交的头逐字节比对 —— 换一台陌生设备时用它确认，不用改任何代码。
`zstdn` 保持 `typeof(&f)`：那十个函数 `<linux/zstd.h>` 已经声明了，`typeof`
不可能和声明漂移；生成的头只覆盖没有包含对应头文件的那些符号。

## 装模块的代价

模块里的编解码器跑起来和内核自带的同样快，但「装」本身不是免费的。两项成本
都在 `post-fs-data` 里一次付清：

| | 实测 |
|---|---|
| 单次 `insmod` | 60–110 ms |
| 单个模块常驻内存 | `coresize` 20–24 KB（`MemFree` 少约 55 KB） |
| 七个全装 | 约 780 ms，`coresize` 150 KB / `MemFree` 少约 400 KB |

这是开机延迟，不是运行期开销 —— 但 `post-fs-data` 会阻塞开机，所以它算数。
**现在加载前先判断，只装内核缺的那些**：算法已经出现在
`zram0/comp_algorithm` 里的，对应模块直接跳过，日志里写一条带原因的 `[SKIP]`。

同一轮排查也把脚本自己的耗时暴露了。这台机器在开机早期，每次外部命令大约
40 ms：

| 操作 | 耗时 |
|---|---|
| 读 `/proc/crypto` | 70 ms |
| 读 `zram0/comp_algorithm` | 63 ms |
| `getprop` 查单个属性 | 55 ms |
| `printf`（Android 上是外部命令，不是内建） | 40 ms |

老脚本每行日志都写成 `printf "%s\n" "$(printf …)"` —— 一行三个 fork ——
三个属性还要分三次查。把这些换成内建（`case`、参数展开、一次 `getprop` 全量）
并把两个 `/proc` 条目各读一次之后：

| | 改前 | 改后 |
|---|---|---|
| 内核已经有这些算法 | 1013 ms，装 7 个 | **701 ms，装 2 个** |
| 内核缺这些算法（需要模块） | 1013 ms，装 7 个 | **906 ms，装 7 个** |

同一台设备、各跑三次取中位数。第二行仍然要装全部，赚到的只是脚本侧的优化，
所以幅度小一些。

## 安装

下载 `zram-lkm-<版本>-arm64.zip`（全 KMI）或
`zram-lkm-<版本>-<kmi>-arm64.zip`（单 KMI），例如 `zram-lkm-v0.1.4-arm64.zip`，
在 KernelSU / APatch 管理器里刷入，重启。

模块在 `post-fs-data` 阶段**只加载模块**，不改动你的 zram 配置 —— 理由见下。

手动加载：

```sh
insmod lz4k-<kmi>.ko
insmod lz4kd-<kmi>.ko
insmod lz4k_oplus-<kmi>.ko

# 确认算法已注册
cat /sys/block/zram0/comp_algorithm
# lzo lzo-rle [lz4] lz4hc zstd deflate lz4k lz4kd lz4k_oplus
#                                      ^^^^ 出现了
```

## 切换算法

**注意：切 `comp_algorithm` 会重置 zram0，现有内容全部丢失。** Android 通常把
zram0 当 swap 用，所以顺序很重要：

```sh
# 1. 记下当前大小
SIZE=$(cat /sys/block/zram0/disksize)

# 2. 停 swap
swapoff /dev/block/zram0

# 3. 切换算法
echo lz4k > /sys/block/zram0/comp_algorithm

# 4. 恢复大小并重新启用
echo "$SIZE" > /sys/block/zram0/disksize
mkswap /dev/block/zram0
swapon /dev/block/zram0
```

想开机自动切换，在模块目录放 `zram_lkm.conf`：

```sh
ALGO=lz4k_oplus
AUTO_SWITCH=1
```

默认 `AUTO_SWITCH=0`。开机阶段自动切换会清掉 swap 里已有的页，内存紧张的
设备上这是实打实的风险，所以默认留给你自己决定时机。

## 选择算法

没有放之四海而皆准的答案，取决于你的负载：

| 场景 | 建议 |
|------|------|
| 内存小、追求压缩率 | `lz4kd`（delta 变体，对相似页更省） |
| 追求低延迟（游戏、前台响应） | `lzo-rle`（内核自带，最快） |
| 折中 | `lz4k` / `lz4k_oplus` |

在 Redmi Pad（`2410CRP4CG`，`SM7675`，厂商内核
`6.1.138-android14-11-g0c3d559bcd85`）上实测：把 60 MB 真实
`.so` 文件写进一个临时 zram 设备。

| 算法 | 写入 | 读回 | 压缩后（原始 63.11 MB） |
|---|---|---|---|
| `lz4k` | 279 MB/s | 526 MB/s | 41.59 MB |
| `lz4k_oplus` | 270 MB/s | 487 MB/s | 41.27 MB |
| `lz4kd` | 256 MB/s | 521 MB/s | 40.57 MB |
| `lzo` | 252 MB/s | 397 MB/s | 40.23 MB |
| `lz4` | 232 MB/s | 487 MB/s | 40.19 MB |
| `lzo-rle` | 223 MB/s | 495 MB/s | 40.42 MB |
| `zstdn` | 137 MB/s | 304 MB/s | 31.13 MB |
| `lz4hc` | 127 MB/s | 400 MB/s | 38.10 MB |
| `zstd` | 116 MB/s | 312 MB/s | 30.99 MB |
| `842` | 69 MB/s | 179 MB/s | 37.25 MB |

一台机器、跑一轮。同一台设备上重复测量，写入抖到 20%、读回抖到 50%，所以这
些数字只能当量级看：lz4 那一家子彼此的差别落在噪声里，真正的差距在
「lz4 一家」到 `lz4hc`/`zstdn`、再到 `842` 之间。**别拿组内排名当结论，比的是组。**

另外，样本是桌面侧的共享库，而手机上 zram 装的是匿名页 —— 这里压缩比好，不等于
你手机上的内存省得多。

**一定要在自己设备、自己数据上量**：网上流传的比值都是别人的设备和别人的
数据。模块自带测量脚本：

```sh
sh /data/adb/modules/zram_lkm/zram-bench.sh
```

它会逐个算法重建 zram0、写入同一份样本（一半重复文本、一半随机字节，比
纯零或纯随机更接近日常负载），输出压缩率和写入耗时。结束后会恢复你原本的
disksize、算法和 swap 状态。

也可以直接看数字：

```sh
grep -E 'orig_data_size|compr_data_size' /sys/block/zram0/mm_stat
```

第 1 列是原始大小，第 2 列是压缩后大小 —— 两者比值就是实际压缩率。

## 还有哪些能做成模块，哪些不能

"能不能用模块加 X"其实有三种答案，值得分开说：

| 类型 | 例子 | 模块能做吗 |
|------|------|-----------|
| 算法注册 | `lz4k`、`lz4kd`、`842` | **能** —— `crypto_register_alg()` 是开放名空间 |
| 整个驱动（前提是内核里它是 `=m`） | `zram`、`zsmalloc` | **能** —— 自带 `.ko`，但要先卸载厂商那份 |
| 编译期代码路径 | `ZRAM_WRITEBACK`、`ZRAM_MULTI_COMP`、`ZRAM_RECOMPRESS` | 内置 `zram` 上**不能**；只能靠上一行绕 |

第三行正是第二行存在的原因。`CONFIG_ZRAM=y` 的内核里，writeback 和
多压缩流的代码根本没编进去，模块变不出来；`CONFIG_ZRAM=m` 的内核则可以
自带一份带这些特性的 zram.ko，代价是替换掉系统的 swap 后端。

本项目**刻意不做**的：

- **带 `MULTI_COMP` / `RECOMPRESS` 的自定义 `zram.ko`。** 收益是真实的
  （按页在快速压缩器和高压比压缩器之间选、冷页就地重压缩），但失败场景是
  一台可能开不了机的设备上直接失去 swap。这应该放在显式 opt-in 后面，
  而不是默认包里。
- **自定义 `zsmalloc.ko`。** 同理；值得要的只有 `ZSMALLOC_STAT` 观测能力，
  为它替换掉承载全部压缩页的分配器不划算。
- **`842`。** 厂商内核普遍没有 `CONFIG_CRYPTO_842`，而且这个算法是为硬件
  加速器设计的，在 zram 上压缩率和速度都输给 lz4。加它只是凑数。

算法注册是唯一一个答案明确为"能"的类型，所以本项目只待在这一行。

## 支持的 KMI

| KMI | 内核 |
|-----|------|
| `android12-5.10` | 5.10 |
| `android13-5.10` | 5.10 |
| `android13-5.15` | 5.15 |
| `android14-5.15` | 5.15 |
| `android14-6.1` | 6.1 |
| `android15-6.6` | 6.6 |
| `android16-6.12` | 6.12 |

**仅 arm64。**

## 更多扩展：换掉 zram.ko 本身

如果设备是 `CONFIG_ZRAM=m`（很多厂商是），那 zram 本身也是模块，
可以**自带一份 zram.ko** 替换厂商的：

```sh
swapoff /dev/block/zram0
rmmod zram
insmod /data/adb/modules/zram_lkm/zram.ko    # 自己编的，可以带新特性
# 重新配置
```

这样能拿到内核编译期根本没有的东西，例如：

- `ZRAM_MULTI_COMP`（多压缩流，6.4+）
- `ZRAM_RECOMPRESS`（写回 + 重压缩，6.6+）
- 更新版 zram 的 bug 修复

**风险明显更高**：替换的是系统的 swap 后端，一旦新 zram.ko 与内核不匹配，
轻则 swap 不可用，重则 OOM。本项目默认**不**做这件事，只在文档里说明可行性。

检查你的设备是否具备前提：

```sh
zcat /proc/config.gz | grep -E '^CONFIG_ZRAM=|^CONFIG_ZSMALLOC='
# CONFIG_ZRAM=m        ← 才能换
# CONFIG_ZRAM=y        ← 编进内核了，换不了
```

## 构建与发布

两个工作流，**刻意分开**：

| 工作流 | 触发 | 是否发布 |
|---|---|---|
| [`ci.yml`](https://github.com/misaka5202/zram-lkm/blob/main/.github/workflows/ci.yml) | push 到 main、PR、手动 | 否，只留 artifact。**默认只编一个 KMI**（android14-6.1），要全量传 `full_matrix: true` |
| [`release.yml`](https://github.com/misaka5202/zram-lkm/blob/main/.github/workflows/release.yml) | 打 tag `vX.Y.Z`、手动指定 tag | 是，**只发预览版** |

两者都调用可复用的
[`build.yml`](https://github.com/misaka5202/zram-lkm/blob/main/.github/workflows/build.yml)，
那个只负责编译打包。把发布从 CI 里拿掉，意味着 CI 绿灯永远不会把坏产物推到
用户面前，而每次发布都对应某个人主动打的 tag。

```sh
git tag v0.1.0
git push origin v0.1.0
```

### 模块目录结构

```
module/
├── module.prop       元数据
├── customize.sh      安装期检查与提示
├── post-fs-data.sh   按 KMI 加载 .ko（为什么必须早，见脚本头部注释）
├── service.sh        late_start：往日志里补一次状态快照
├── uninstall.sh      清理；刻意不 rmmod
└── action.sh         「操作」按钮：已加载模块、crypto 列表、实时 comp_algorithm
```

`.ko` 放在模块自己的 `ko/` 目录里，从那里 insmod，**不再放进
`system/lib/modules/`**。KernelSU 只有在装了 metamodule 时才会挂载 `system/`，
原来那种放法等于悄悄给用户加了一个前提，没装 metamodule 的人会直接加载失败。

## 源码与许可证

算法源码来自 [SukiSU_patch](https://github.com/Pixel-Tent/SukiSU_patch) /
[ABK](https://github.com/cachiusa/AnyKernel3) 的内核树补丁，本项目把它们改造为
树外模块（补 `MODULE_ALIAS_CRYPTO`、整理 include、写独立 Makefile）。

| 组件 | 来源 | 许可证 |
|------|------|--------|
| `lz4k` / `lz4kd` | 华为（Huawei Technologies） | GPL-2.0 |
| `lz4k_oplus` | OPPO 分支 | GPL-2.0 |
| `extra/kallrecon/` | [Dere3046/KallRecon](https://github.com/Dere3046/KallRecon) | GPL-2.0 |

**GPL-2.0 要求分发二进制时提供对应源码。** 每个 Release 附带的
`source-<tag>.tar.gz` 就是编出该版本 ko 的完整源码快照。

**免责声明**：加载内核模块等同于以最高权限执行内核代码；切换 zram 压缩算法
会清空该设备上已有的压缩数据。请确保有 fastboot / recovery 恢复手段。