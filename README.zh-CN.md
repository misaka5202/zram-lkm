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

## 安装

下载 `zram-lkm-arm64.zip`（全 KMI）或 `zram-lkm-<kmi>-arm64.zip`（单 KMI），
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

**GPL-2.0 要求分发二进制时提供对应源码。** 每个 Release 附带的
`source-<tag>.tar.gz` 就是编出该版本 ko 的完整源码快照。

**免责声明**：加载内核模块等同于以最高权限执行内核代码；切换 zram 压缩算法
会清空该设备上已有的压缩数据。请确保有 fastboot / recovery 恢复手段。