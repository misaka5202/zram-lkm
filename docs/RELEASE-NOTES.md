# ZRAM LKM v0.1.4 (preview)

This release is about symbols, and about what loading a module actually costs.

## The symbol layer

Vendor kernels can leave a function in `kallsyms` and still not export it, so a
module that references it statically dies with `Unknown symbol` even though the
code is right there. `842`, `lz4hc` and `zstdn` now resolve those addresses at
init through a kprobe on `kallsyms_lookup_name()`, and call through pointers
marked `__nocfi` (`CONFIG_CFI_CLANG` would otherwise refuse).

The pointer types themselves are generated from the running kernel's BTF by
`scripts/gen_symproto.py`, not typed by hand — the script also answers "which
symbols does this kernel lack" from a built `.ko`.

`842` / `lz4hc` / `zstdn` still load on kernels that never exported those
symbols. The Action button now reports exactly which symbols this kernel is
missing, instead of leaving you with a bare `Unknown symbol` in a log.

## What it costs — and what was cut

Runtime is measurably identical to a kernel that has the codecs built in: an
A/B on the same device, alternating, gave differences inside a ±1.5% noise floor
set by control rows that cannot differ.

Loading, on the other hand, is not free: 60–110 ms per `insmod` and 20–24 KB
resident, all paid inside `post-fs-data`, which blocks boot. So the loader now
**skips modules for algorithms the kernel already provides**, and the script
itself lost most of its process-creation overhead (`printf` is an external
binary on Android; the old log line forked three times).

| | before | after |
|---|---|---|
| kernel already has the algorithms | 1013 ms, 7 modules | 701 ms, 2 modules |
| kernel lacks them | 1013 ms, 7 modules | 906 ms, 7 modules |

## Also

- Japanese translation completed (it covered 26 of 48 strings), and
  `scripts/check-i18n.sh` now fails CI when a language drifts.
- `uninstall.sh` says what it always meant to say: the algorithms stay
  registered until the next reboot.
- Known limitation: if the vendor registers its own `842` at `cra_priority 100`,
  the module's copy is never selected — it loads and does nothing. Harmless, but
  it will not take over. Check with `grep -A3 'name *: 842' /proc/crypto`.

---

# ZRAM LKM v0.1.4（中文）

这一版讲两件事：符号，以及「装模块」到底要付多少代价。

## 符号层

厂商内核可能把函数留在 `kallsyms` 里却不导出，模块静态引用它就 `Unknown
symbol` 装不上 —— 哪怕代码本体就在那儿。`842`、`lz4hc`、`zstdn` 现在改成
init 时通过 kprobe 取 `kallsyms_lookup_name()` 解析地址，经函数指针调用，
调用点标 `__nocfi`（否则 `CONFIG_CFI_CLANG` 会拒）。

指针类型不再是手打的，改由 `scripts/gen_symproto.py` 从运行中内核的 BTF
生成；这个脚本还能从编译好的 `.ko` 反推「本内核缺哪些符号」。

所以这三个模块在从没导出过那些符号的内核上仍然装得上。模块页的「操作」按钮
现在会直接列出本内核缺哪几个符号，而不是让你去日志里找一句 `Unknown symbol`。

## 代价，以及砍掉了什么

运行期实测与「把这些算法编进内核」无差别：同一台设备上交替测量，差值落在
±1.5% 的噪声底内 —— 而这个底是那几行物理上不可能有差别的对照组定出来的。

但「装」不是免费的：每次 `insmod` 60–110 ms、每个模块常驻 20–24 KB，全都
付在阻塞开机的 `post-fs-data` 里。所以现在**内核已经提供该算法就跳过对应
模块**；脚本本身也去掉了大部分创建进程的开销（Android 上 `printf` 是外部
命令，老代码每行日志要 fork 三次）。

| | 改前 | 改后 |
|---|---|---|
| 内核已有这些算法 | 1013 ms，装 7 个 | 701 ms，装 2 个 |
| 内核缺这些算法 | 1013 ms，装 7 个 | 906 ms，装 7 个 |

## 其他

- 日文翻译补齐（原来 48 条只覆盖 26 条），`scripts/check-i18n.sh` 接进 CI，
  某种语言漂移会直接失败。
- `uninstall.sh` 终于把它一直想说的话说出来了：算法会保持注册到下次重启。
- 已知限制：厂商若把自己的 `842` 注册成 `cra_priority 100`，模块那份永远
  选不上 —— 装上、注册成功、然后什么都不做。无害，但别指望它接管。
  判断方法：`grep -A3 'name *: 842' /proc/crypto`。