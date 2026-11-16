# Changelog

[English](CHANGELOG.md)

## 版本号说明

这个项目**还没有正式版本**。目前所有发布都是 GitHub pre-release（预览版）。

早期版本用的是 `1.0.x`，但那套号看起来像已经稳定，实际只验证到"能编译 +
单机手动加载"。发布已全部删除，版本重新从 `0.1.0` 开始。

`versionCode` 用日期编码（`v0.1.0` → `20261115`）。老的 `1.0.x` 用的是
`10001`–`10003` 这种小数字；如果新版本继续用小数字，KernelSU 更新器会认为
版本更低而不推送。日期编码天然单调递增，不会再因版本重置而倒退。

## 未发布 — 符号这一层

这几项都源自同一件事：厂商内核可能把函数留在 `kallsyms` 里却没有导出，
模块静态引用它就会 `Unknown symbol` 装不上，哪怕代码本体就在那儿。

### 注册与编解码符号改运行时解析

`842`、`lz4hc`、`zstdn` 都要调 `crypto_register_scomp()` /
`crypto_unregister_scomp()`；`lz4hc` 还要 `LZ4_compress_HC()` 和
`LZ4_decompress_safe()`；`zstdn` 要用十个 `zstd_*()` 入口。这些在部分厂商
内核上存在但不在 `__ksymtab` 里。

现在改成 init 时通过 kprobe 取 `kallsyms_lookup_name()`（见
`extra/compat/zram_symres.h`）解析出地址，经函数指针调用。凡是通过指针
发起的调用，所在函数都标了 `__nocfi` —— `CONFIG_CFI_CLANG` 会检查间接
调用目标，不标就被拒。

在 Qualcomm SM7675 / 6.1.138 上实测：不需要绕符号的四个算法
（`lz4k`、`lz4kd`、`lz4k_oplus`、`zram_list`）照常加载，需要绕的三个
也加载成功了，此前它们是装不上的。

### 指针类型改由 BTF 生成

`842` 和 `lz4hc` 原来手写这些指针的签名。现在类型来自
`extra/compat/zram_symproto.h`，由 `scripts/gen_symproto.py` 从运行中内核的
`/sys/kernel/btf/vmlinux` 生成 —— 类型是内核实际有的那个，不是谁手打的
那个；换一台设备也只是重跑一条命令。

`zstdn` 保持 `typeof(&f)`：那几个函数由 `<linux/zstd.h>` 声明，`typeof`
不可能和声明漂移；生成的头只覆盖没有包含对应头文件的符号。

脚本还能反着用（`--from-ko`）：读一个编译好的 `.ko`，报出它的未定义符号里
哪些是内核 BTF 认识的 —— 就是下面设备端检查用的同一份清单。

### 构建期记录未定义符号，设备端核对导出表

`scripts/build_modules.sh` 在编译时把每个模块的未定义符号写进
`ko/symcheck-<kmi>.txt`。`action.sh` 拿它比对 `/proc/kallsyms` 里的
`__ksymtab_` 条目，直接报出本内核缺哪几个，而不是让用户自己去
`post-fs-data.sh` 的日志里翻。

`/proc/kallsyms` 只读一次、单趟比对：逐符号 grep 会让二十多万行的文件把
「操作」按钮按出假死。

### 算法为什么不需要拆

每个压缩算法本来就是独立的 `.ko`（单独编译、单独加载），装不上也不会连累
别的：`post-fs-data.sh` 给它记一条 `[FAIL]` 就继续下一个。上面那台设备上一
共七个模块、三个失败四个正常，降级是天然的。这一项没有要改的。

### 只装内核缺的模块

模块里的编解码器在运行期不额外收费，但「装」不是免费的：本机每次 `insmod`
要 60–110 ms，每个模块常驻 20–24 KB。七个模块意味着开机阻塞约 780 ms、
`MemFree` 少约 400 KB —— 而且在把这些算法全编进内核的机器上，这些成本付完
之后模块根本不会被选中。

`post-fs-data.sh` 现在只读一次 `zram0/comp_algorithm`，算法已经在里面的模块
直接跳过，日志记 `[SKIP] …（内核已经提供该算法）`。`zram_list` 放到最后，
只有确实装了东西才装 —— 它的职责本来就是让模块提供的算法显示出来。

同一轮排查还发现脚本把时间花在创建进程上：这台机器开机早期的外部命令大约
40 ms 一次，而 Android 上 `printf` 是外部命令，老脚本每行日志要经命令替换
调它两次。另一半是读 `/proc/crypto`（70 ms）和分三次 `getprop`（每次 55 ms）。

| | 改前 | 改后 |
|---|---|---|
| 内核已经有这些算法 | 1013 ms，装 7 个 | 701 ms，装 2 个 |
| 内核缺这些算法 | 1013 ms，装 7 个 | 906 ms，装 7 个 |

各跑三次取中位数。判据刻意用 `comp_algorithm` 而不是 `/proc/crypto`：它直接
回答「zram 能不能用」，而且日志本来就要读它，所以检查只多一次文件读取而不是
两次。

### 和「全部编进内核」的版本实测对比

刷了一颗把全部算法编进去的自制 6.1，才做成了真正的 A/B：同一台设备上同一个
编解码器存在两份 —— 一份是内核代码直接调用，一份经解析出的指针调用。交替测量，
每次配置丢掉第一个热身样本，各取 9–13 个样本：

| 算法 | 内核内置 | 模块 |
|---|---|---|
| `lz4hc` | 574 ms | 568 ms |
| `lz4k` | 207 ms | 215 ms |
| `lz4kd` | 206 ms | 200 ms |
| `lz4k_oplus` | 233 ms | 236 ms |
| `lzo` / `zstd` / `842`（对照） | — | 都在 ±1.5% 内 |

对照组两边跑的本来就是同一份内核代码，物理上不可能有差别，它们把噪声底定在
±1.5%。实验组全部落在里面，而且正负号在算法之间来回翻 —— 没有差别可报。
两种配置下压缩后字节数完全相同，说明跑的确实是同一份编解码器。

这次实测带出两件与速度无关的事：

- **`842` 模块在这类内核上是废的。** 厂商把内置 `842` 注册成
  `cra_priority = 100`，我们的是 0，永远选不上。验证方法：让一个 zram 设备
  用着 `842`，模块引用计数始终是 0，`rmmod` 直接成功。无害，但别指望它接管。
  内核没有内置 `842` 时它仍是唯一来源。
- **第一版测错了。** 它报 `lz4hc` 模块版慢 5%，而且三趟都稳定复现。真实原因是
  `insmod` 之后第一个样本是冷的 —— 模块代码段刚映射，i-cache 和分支预测器都空。
  丢掉一次热身样本后差距完全消失。交替测量救不了：冷样本跟着每一次 `insmod` 走。

### 实测数字，和真正补全的翻译

README 的算法段落原来只有一句「自己量」。现在多了一轮实测 —— 在 Redmi Pad
（`2410CRP4CG`，`SM7675`，`6.1.138`）上把 60 MB 真实 `.so` 写进临时 zram ——
并且把同一台设备上的抖动（写入 ±20%、读回 ±50%）写在同一张表下面，还注明
样本是桌面的共享库、而手机 zram 装的是匿名页，两者不能直接类比。`842` 排在
最后（69 MB/s），这和上游对它的说法一致：参考实现，不是快的那种。

README 也第一次写了符号那一层：哪些模块需要运行时解析、为什么指针要标
`__nocfi`、查找的代价有多大、以及换新设备时怎么用
`scripts/gen_symproto.py` 核对。

日文翻译原来只覆盖 48 条里的 26 条，日文设备上「内核导出检查」和主线标签这些
全都会回落成英文。现在补齐了，并且 `scripts/check-i18n.sh` 接进了 `ci.yml`：
脚本引用了英文基线里没有的键、或者三种语言出现偏移，CI 直接失败。另外删掉了
一条死文案（`M_S_LOADED`，没有任何脚本用过），把三条卸载提示真正接到
`uninstall.sh` 里输出，而不是定义在那儿没人管。

## v0.1.0 — 第一个打过 tag 的预览版

`versionCode` 20261115。

模块打包和安装方式重整，算法本身没有变化（仍是 lz4k / lz4kd / lz4k_oplus /
lz4hc / 842，外加 zram_list）。

- **`.ko` 不再放进 `system/lib/modules/`**。KernelSU 只有装了 metamodule 时才挂载
  `system/`，原布局等于给用户加了一个看不见的前提：没装就装完什么都不会发生。
  现在放在模块自己的 `ko/` 目录，`post-fs-data.sh` 直接从那里 insmod。
- **CI 与发布解耦**。`ci.yml` 只编译，产物留 artifact；`release.yml` 只在打 tag
  时运行并强制 `--prerelease`。CI 绿灯不再可能把未验证的产物推给用户。
- 模块目录按 KernelSU 规范整理：`MODDIR=${0%/*}`、去掉 `set_perm*`、新增
  `action.sh`。
- **合并包会加载错 KMI 的模块**。`post-fs-data.sh` 原本是"ko/ 下有什么就
  insmod 什么"，单 KMI 包没问题，但合并包里有 5 个算法 x 7 个 KMI = 35 个
  .ko，会挨个去装别的内核版本编的模块。改布局时那步按 KMI 筛选的动作被
  一起删掉了，现在补回脚本里：内核主版本优先推导 KMI，只加载匹配的那一组。
- 修 `842` 无法加载：`module_param_named` 写在了被两个编译单元共同 include 的
  头文件里，生成两份同名 sysfs 参数，模块在加载阶段就 `-EEXIST` 失败（连 init
  都跑不到）。
- **`zram_list` 会吃掉列表里的名字**。原地过滤时用 `scnprintf` 写回，而它
  写完会补一个 `\0`，正好覆盖还没读到的下一个 token 的首字节——实测把
  `lzo-rle` 变成空串丢掉。改成按字节搬运，最后统一补结尾。
- 修 `zram_list` 只加自己那五个名字：厂商自带的 `zstdp` 已注册却同样看不见，
  现在一并补上；反过来厂商 `backends[]` 里的 `zstdn` / `zstdn_o` 根本没注册，
  现在会被过滤掉，不再误导用户去选一个不存在的算法。

## v0.1.3 — 842 解压的两处上游溢出修复

`versionCode` 20261118。**安全修复，建议升级。**

审计 vendored 的 842 编解码器时发现，我们用的 6.1 版本缺两个上游修复，
而这两个缺陷**恰好落在本模块存在的意义上**——zram 的压缩回写路径。

**1. index / short-data 输出溢出**（上游 `38ed7182f349`）

```c
if (size > p->olen)      // ← 我们这份没有
    return -ENOSPC;
memcpy(p->out, &p->ostart[offset], size);
p->olen -= size;
```

indexed copy 写 2/4/8 字节、short-data 最多写 7 字节，两者都不检查调用方给的
容量。写穿偏小的目标缓冲区之后，`p->olen` 是**无符号**的，会下溢成一个巨大值，
于是流里后续所有 `olen` 边界检查全部失效，继续往界外写。上游提交里写明：篡改
zram backing device 上的压缩数据即可触达，KASAN 内核报
`vmalloc-out-of-bounds` 于 `__do_index()` / `sw842_decompress()`。

**2. repeat 模板缺少完整历史块**（上游 `deb631649882`）

```c
if (p.out == out)              // 旧：只在完全没输出时拒绝
if (p.out - p.ostart < 8)      // 新：至少要有完整 8 字节块
```

repeat 复制前 8 字节输出块。short-data 可以先产出 1~7 字节，紧接一个 repeat
就会从输出缓冲区**起始位置之前**读，取决于映射可能 fault，或把相邻内核内存读进
解压结果。

两处都已在本地应用并逐行对照上游 master 验证一致。**6.15 及更早的内核都没有
这个修复**，只有 mainline 有。

本机 `CONFIG_CRYPTO_USER` 未开启，`AF_ALG` 不可用，非特权进程无法直接喂数据；
但 zram 回写路径与开着 `AF_ALG` 的设备仍然受影响，所以照修不误。

## v0.1.2 — 新增 zstdn / zstdn_o

`versionCode` 20261117。

这两个名字是 OPPO/一加的自有算法，之前被 `zram_list` 当作"未注册的死条目"过滤掉了。
一加 15（sm8850）的源码证明它们是真的：`vendor/oplus/kernel/mm/zstd_o/`，
`crypto_zstd.c` 注册 `zstdn_o`，注释写明 `replace zstdn -> zstdn_o`，而真正区别于
普通 zstd 的只有一行：

```c
#define ZSTD_DEF_LEVEL	1
```

内核自带 zstd 跑 level 3，这个是 level 1 —— 用压缩率换速度，换页设备上正是这个取向。

OPPO 把整套 zstd（27 个文件）编进自己的模块，因为他们是树外构建。本项目的做法和
`lz4hc` 一样：内核已经编进 zstd 编解码器并导出了单遍 API
（`zstd_get_params` / `zstd_cctx_workspace_bound` / `zstd_init_cctx` /
`zstd_compress_cctx` 及 dctx 对应物），所以这里只做注册，约 500 行。

同时注册 `zstdn` 和 `zstdn_o` 两个名字，因为 OPPO 自己的列表（`backends[]` 写
`zstdn`）和它的注册（模块注册 `zstdn_o`）是错位的，两种固件都可能要其中任意一个。

实测（32MB 混合样本，本机 android14-6.1）：

| 算法 | 压缩率 | 耗时 |
|---|---|---|
| zstdn | 1.96x | — |
| zstdn_o | 1.96x | 116ms |

接入后 `comp_algorithm` 变成：

```
lzo lzo-rle lz4 zstd lz4k zstdn zstdn_o [lz4k_oplus] lz4kd lz4hc 842
```

厂商原本那两个死条目现在是真算法。

## v0.1.1 — zram_list 随包自启

`versionCode` 20261116。

之前 `zram_list` 被排除在模块包外，理由是"改写内核文本且未验证"。它已经过反复
手动验证（只钩一个函数 `zcomp_available_show`，失败时静默放弃），而**不加载它
就等于模块提供的算法永远不出现在任何读取 `comp_algorithm` 的界面里**——包括
Scene：它的 APK 里没有任何硬编码压缩算法名，算法列表完全来自
`/sys/block/zram0/comp_algorithm`。

所以：

- `zram_list` 现在随包自启，合并包和单 KMI 包都带
- 加载时机不再要求"zram 已就绪"：找不到就每 3 秒重试，最多约 1 分钟
  （模块加载顺序不保证，之前一次性放弃会让开机早期加载失败后永久失效）

实测：加载后 `comp_algorithm` 从
`lzo lzo-rle lz4 zstd lz4k zstdn zstdn_o [lz4k_oplus]`
变为
`lzo lzo-rle lz4 zstd lz4k [lz4k_oplus] lz4kd lz4hc 842`——
模块提供的算法出现了，厂商列表里没注册的 `zstdn`/`zstdn_o` 被过滤掉。
