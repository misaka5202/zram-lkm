# Changelog

[English](CHANGELOG.md)

## 版本号说明

这个项目**还没有正式版本**。目前所有发布都是 GitHub pre-release（预览版）。

早期版本用的是 `1.0.x`，但那套号看起来像已经稳定，实际只验证到"能编译 +
单机手动加载"。发布已全部删除，版本重新从 `0.1.0` 开始。

`versionCode` 用日期编码（`v0.1.0` → `20261115`）。老的 `1.0.x` 用的是
`10001`–`10003` 这种小数字；如果新版本继续用小数字，KernelSU 更新器会认为
版本更低而不推送。日期编码天然单调递增，不会再因版本重置而倒退。

## v0.1.6（未发布）

### 变更

**KallRecon 成为首选解析途径。** `extra/kallrecon/` 直接解析内核的 kallsyms
表，符号解析不再以 kprobe 为前提：不依赖 `register_kprobe`，不受 kprobe 黑名单
限制（`aarch64_insn_patch_text_nosync` 这类也能查到），也不受 `kptr_restrict`
影响。KallRecon 布局探测失败时仍退回 kprobe 探测。五个解析符号的模块
（lz4hc / 842 / zstdn / zram_list 与解析器自身）统一走
`extra/compat/zram_symres.h`。

**`zram_list` 不再自带第二份解析实现。** 它的 `zl_lookup_probe`/`zl_lookup`
与 `zr_lookup_probe`/`zr_lookup` 逐字相同，现在五个模块共用一个入口。

### 验证

全 KMI 矩阵编译通过；6.1 产物的 `.symtab` 里 `find_kallsyms_base` /
`kallrecon_klp` 已解析（不再是未定义符号），确认引擎真的链进去了。

## v0.1.5

`versionCode` 20261120。

### 修复

**`lz4k_oplus` 解压越界写。** 小字面量快路径拷贝 `NR_COPY_MIN`（32）字节时从不检查
**目标缓冲区**余量，而紧邻其下的大字面量分支一直有。zram 解压的是 swap 后备设备上
可被破坏的数据（攻击面和本项目已修的两处上游 842 CVE 相同），构造的压缩流最多能
越过 vmalloc 输出缓冲区约 31 字节。现在两个分支都补上了同仓库华为版解码器
（`extra/lz4k/lz4k_decode.c`）一直具备的目标检查。

**畸形输入下的 NULL 解引用。** `get_size()` 在扩展长度越过输入末尾时返回 NULL，
两处调用点却直接把它交给 `literal_decompress()` 并立即解引用。入口也补上了华为版
一直有的非空与最小长度校验。

**root 脚本经由全局可写路径写入。** `/data/local/tmp/zram_lkm.log`（以及 `zram-bench`
工作目录）被 root 脚本截断、追加且没有符号链接检查，而 `/data/local/tmp` 任何应用都可
写——预置一个符号链接就能让 root 截断或追加任意文件。日志已移到 `/data/adb`
（仅 root）；旧位置迁移一次为 `.old`，若它是符号链接则直接删除、绝不跟随。

**workflow 输入注入。** `release.yml` 把 `${{ inputs.tag }}` 插值进 `run:` 块，而
Actions 是在 shell 解析**之前**做文本替换：含 `"`、`;` 或 `$( )` 的 tag 能逃逸引号，
在以 `contents: write` 运行的 runner 上执行任意命令。现改为经 `env` 传入，并加锚定
白名单与行数校验。

**inline hook 的指令缓存未刷新。** `zram_list` 用普通存储把 trampoline 填进可执行的
vmalloc 页，arm64 上 icache 与 dcache 不保证一致，而 `aarch64_insn_patch_text_nosync`
只刷目标那一处指令、管不到 trampoline；别的 CPU 跳到那里可能取到陈旧字节。现在在
patch 入口前对 trampoline 执行 `flush_icache_range()`。

**诊断字符串损坏。** `zram_list_main.c` 两条日志仍残留被拼坏的 `'+ BS + 'n`
（本应是 `\n`，早前脚本替换事故遗留），打印出来是字面量而非换行。

### 变更

**发布包名带上版本号。** 产物改为 `zram-lkm-<version>-arm64.zip`、
`zram-lkm-<version>-<kmi>-arm64.zip` 与 `source-<version>.tar.gz`——此前每次下载
文件名完全相同，看不出装的是哪个构建。版本从 `module.prop` 读取，发布不可能再悄悄
产出上一个版本的文件名。

## v0.1.4

`versionCode` 20261119。

### 修复

**`842`、`lz4hc`、`zstdn` 改为运行时解析符号。** 厂商内核可能把函数保留在
`kallsyms` 中但不导出，静态引用会在 `insmod` 时报 `Unknown symbol`。现改为 init
阶段通过 kprobe 获取 `kallsyms_lookup_name()` 并解析地址
（`extra/compat/zram_symres.h`），经函数指针调用，调用点标注 `__nocfi`
（`CONFIG_CFI_CLANG` 会拒绝未标注的间接调用）。

三个模块在从未导出这些符号的内核上可正常加载。

**`uninstall.sh` 提示信息。** 现明确说明已注册的算法保持有效至下次重启。

### 新增

- `scripts/gen_symproto.py` —— 从运行中内核的 BTF 生成指针原型；亦可反查已
  编译 `.ko` 需要但当前内核未导出的符号。
- 「操作」按钮输出改为列出本内核具体缺失的符号。
- 日文翻译：26/48 → 48/48；`scripts/check-i18n.sh` 接入 CI，翻译漂移会导致
  构建失败。

### 变更

- 内核已提供某压缩算法时，跳过对应模块的加载。
- `post-fs-data` 脚本：移除逐行创建进程的开销（Android 上 `printf` 是外部
  二进制，原实现每行日志 fork 三次）。

### 性能

| 条件 | 改前 | 改后 |
|---|---|---|
| 内核已提供这些算法 | 1013 ms，加载 7 个模块 | 701 ms，加载 2 个模块 |
| 内核缺少这些算法 | 1013 ms，加载 7 个模块 | 906 ms，加载 7 个模块 |

单模块加载开销 60–110 ms，常驻 20–24 KB。运行期吞吐与「算法编入内核」的对照
版本差异落在 ±1.5% 噪声底内（同设备交替测量）。

### 已知问题

- 若厂商把自己的 `842` 注册为 `cra_priority 100`，模块内的副本不会被选中：
  可正常加载并注册，但不接管该算法。判断方法：
  `grep -A3 'name *: 842' /proc/crypto`。

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
