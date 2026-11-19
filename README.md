# ZRAM LKM

**Extend ZRAM compression algorithms on a stock Android GKI kernel with loadable modules — no kernel rebuild, no boot image flashing.**

[中文说明](README.zh-CN.md) · [Releases](../../releases/latest)

---

Vendor kernels usually keep only `lzo-rle` for ZRAM, trimming every other
algorithm at build time to satisfy GKI ABI checks. This project packages those
algorithms as `.ko` files you `insmod` — and in fact they load *on demand* when
zram is asked to use them.

## Project status

**No stable release yet.** Every tag here is a GitHub **pre-release (preview)**.
These modules are verified to build for all seven KMIs and to load and compress
on one device; they have not been regression-tested across vendors, so treat
them as builds to try and report on.

| | |
|---|---|
| What CI does | Compiles every KMI, publishes **nothing**; `.ko` files stay as Actions artifacts. |
| What Release does | Runs only on a tag push (`vX.Y.Z`) and publishes a **pre-release**. |
| Where to report | [New issue](https://github.com/misaka5202/zram-lkm/issues/new/choose) |

## Algorithms

| Module | Algorithm name | Origin | Versus lzo-rle |
|--------|---------------|--------|----------------|
| `lz4k` | `lz4k` | Huawei | better ratio, speed close to LZ4 |
| `lz4kd` | `lz4kd` | Huawei | delta variant, exploits page similarity |
| `lz4k_oplus` | `lz4k_oplus` | OPPO | OPPO's branch of LZ4K |
| `lz4hc` | `lz4hc` | upstream LZ4 | best ratio of the LZ4 family; `lz4hc_level=` 3-16 |
| `842` | `842` | IBM | carries the lib/842 reference codec; vendor kernels trim both `CONFIG_CRYPTO_842` and the codec itself. Slow -- present for completeness, not as a default |
| `zstdn` / `zstdn_o` | `zstdn`, `zstdn_o` | OPPO | OnePlus ships these as `oplus_bsp_zstdn`; same codec as `zstd` but driven at level 1 (`ZSTD_DEF_LEVEL 1`). Thin module: reuses the kernel's zstd, no codec copy |

`lz4hc` is a registration-only module: it calls the `LZ4_compress_HC` /
`LZ4_decompress_safe` the kernel already exports, so it carries no codec of its
own. Vendor kernels usually build that codec (`CONFIG_LZ4HC_COMPRESS=y`) and
trim only the crypto registration.

**How many algorithms are there in total?** Upstream has seven names zram can
use, and zram itself enforces none of them — see
[docs/ZRAM-ALGORITHMS.md](docs/ZRAM-ALGORITHMS.md) for the list, why
`comp_algorithm` only ever shows a subset, and how to check a device.

## Why this can be a module

Compression algorithms are not private kernel structures — they live in the
crypto algorithm namespace:

```
zram writes comp_algorithm
      ↓
crypto_alloc_comp("lz4k")
      ↓
not found in kernel → request_module("crypto-lz4k")
      ↓
modprobe matches MODULE_ALIAS_CRYPTO("lz4k") in lz4k.ko
      ↓
module loads → crypto_register_alg() → zram gets the algorithm
```

Consequences:

- `CONFIG_CRYPTO_*` only decides which algorithms the kernel **ships with**;
  it does not prevent **adding** more.
- A module carrying `MODULE_ALIAS_CRYPTO(...)` is pulled in by
  `request_module`, so no manual `insmod` is needed.
- The algorithms are independent of each other; one failing to build does not
  affect the rest.

Contrast with what a module **cannot** do: `CONFIG_ZRAM_WRITEBACK` or
`CONFIG_CFS_BANDWIDTH` are code-path switches. The code is removed by `#ifdef`,
so there is nothing for a module to hook. Compression algorithms are not in
that category.

## Symbols the vendor did not export

Some vendor kernels keep a function in `kallsyms` and still do not export it.
A module that references such a function statically fails to load with
`Unknown symbol`, even though the code sits right there in the image.

Three of the modules are in that position on Qualcomm `SM7675 / 6.1.138`:

| Module | Symbols it needs at run time |
|---|---|
| `842` | `crypto_register_scomp`, `crypto_unregister_scomp` |
| `lz4hc` | the two above, plus `LZ4_compress_HC` and `LZ4_decompress_safe` |
| `zstdn` | the two above, plus ten `zstd_*()` entry points |

They resolve those addresses at init instead. `extra/compat/zram_symres.h`
tries [**KallRecon**](https://github.com/Dere3046/KallRecon) first
(`extra/kallrecon/`, vendored byte-for-byte from upstream `lib/`): it parses the
kernel's kallsyms table directly, so resolution needs no kprobe, is unaffected
by `kptr_restrict`, and can even find targets on the kprobe blacklist. When KallRecon's layout
discovery fails it falls back to the older route, a kprobe on
`kallsyms_lookup_name()`. Calls go through function pointers, and every function
that does so is marked `__nocfi` — `CONFIG_CFI_CLANG` validates indirect call
targets and would otherwise refuse the call.

**What it costs.** The lookups happen once, at `insmod`. Measured load time does
not move with the number of symbols: `lz4k` (0 symbols), `lz4hc` (4) and
`zstdn` (12) all land in the same 50–90 ms band, which is the module loader
itself. At run time the only difference is one more indirect branch per codec
call, and only on `lz4hc` and `zstdn` — `842` carries its codec, so its hot
path has none.

### Measured against a kernel that has them built in

"One more indirect branch per call" is an argument. Here is the measurement,
made possible by flashing a kernel that builds all of these in, so the same
algorithm exists twice on the same device: once as kernel text called directly,
once as a module reached through the resolved pointers.

`Redmi Pad 2410CRP4CG` / `SM7675` / `6.1.138-android14-11-g5929004f86ffc-…-4k`.
60 MB of real `.so` files, fresh zram device per sample, median of 9–13 samples,
native and module measurements alternating so drift cancels:

| Algorithm | built into the kernel | from the module | difference |
|---|---|---|---|
| `lz4hc` | 574 ms | 568 ms | −1.0% |
| `lz4k` | 207 ms | 215 ms | +3.9% |
| `lz4kd` | 206 ms | 200 ms | −2.9% |
| `lz4k_oplus` | 233 ms | 236 ms | +1.3% |
| `lzo` — control, both rows are kernel code | 228 ms | 229 ms | +0.4% |
| `zstd` — control | 533 ms | 525 ms | −1.5% |
| `842` — control, the module's copy is never selected | 839 ms | 841 ms | +0.2% |

The three control rows cannot differ, and they bound the noise floor at ±1.5%.
Per-sample spread is 3–10%, so a 4% move in a median of nine samples is not a
signal; across the four algorithms the sign flips, which is what "no difference"
looks like. Compressed size is byte-identical in both configurations
(lz4hc: 38,095,631 either way), so both really are running the same codec.

**Measurement note, because it cost me an hour.** The first attempt reported
`lz4hc` 5% slower from the module, reproducibly, across three passes. It was
wrong: the first sample after `insmod` is always slow, because the module's text
is freshly mapped and its i-cache and branch-predictor state are cold. Warming
up once and discarding that sample removed the gap entirely. Alternating the two
configurations does *not* fix this — the cold sample travels with each `insmod`.

### If your kernel already ships these algorithms

The module registers the same algorithm names the kernel does, so which
implementation `zram` gets depends on `cra_priority`:

| Algorithm | Priority | Who wins |
|---|---|---|
| `lz4k` `lz4kd` `lz4k_oplus` `lz4hc` | kernel 0, module 0 | the newer registration — the module, once `insmod`'d. Same codec either way |
| `842` | **kernel 100**, module 0 | always the kernel. The module loads, registers, and is never selected |
| `zstdn` `zstdn_o` | OPPO-specific, usually absent | the module is the only source |

The `842` case is real: verified on the kernel above by holding a zram device on
`842` and watching the module's reference count stay at 0 while `rmmod` succeeded.
It is harmless — the module just sits there — but if you installed it expecting
it to take over, it will not. Raising the module's `cra_priority` above the
kernel's would flip that; it buys nothing, since both run the same `lib/842`.

The practical read: on a kernel that builds all ten algorithms in, the module
adds only `zstdn` / `zstdn_o`. Everything else is a duplicate that is neither
faster nor slower.

**What it needs.** `CONFIG_KALLSYMS_ALL`. If the function is absent from the
kernel entirely, nothing can help; the module then fails at init and names the
symbol it could not find.

**Find out what your kernel lacks.** The build writes each module's
undefined-symbol list to `ko/symcheck-<kmi>.txt`; the Action button compares it
against the `__ksymtab_` entries in `/proc/kallsyms` and prints exactly which
ones this kernel does not export — so an issue can say what is missing instead
of quoting a bare `Unknown symbol`.

**Where the pointer types come from.** `extra/compat/zram_symproto.h` is
generated by `scripts/gen_symproto.py` from the kernel's own BTF — the running
image's description of its own types, not a signature typed by hand:

```sh
python3 scripts/gen_symproto.py --btf vmlinux.btf \
    --symbols crypto_register_scomp crypto_unregister_scomp \
              LZ4_compress_HC LZ4_decompress_safe \
    --out extra/compat/zram_symproto.h
```

`--from-ko` works backwards from a built module, and `--verify` regenerates and
diffs against the committed header — that is how you check an unfamiliar device
without editing anything. `zstdn` stays on `typeof(&f)`, because `<linux/zstd.h>`
already declares those ten functions and `typeof` cannot drift from a
declaration; the generated header covers only the symbols whose headers are not
included.

## What loading costs

Even though a module's codec runs at the same speed as the kernel's own, a
module is not free. Two costs are paid once, inside `post-fs-data`:

| | measured |
|---|---|
| `insmod`, per module | 60–110 ms |
| resident memory, per module | 20–24 KB `coresize` (~55 KB of `MemFree`) |
| all seven loaded | ~780 ms, ~150 KB `coresize` / ~400 KB `MemFree` |

That is boot latency rather than runtime cost — but `post-fs-data` blocks boot,
so it counts. **The loader now checks first and loads only what the kernel
lacks**: if an algorithm already appears in `zram0/comp_algorithm`, its module
is skipped with a `[SKIP]` line naming the reason.

The same work exposed where the script was spending its time. During early boot
this device charges about 40 ms per external command:

| operation | cost |
|---|---|
| reading `/proc/crypto` | 70 ms |
| reading `zram0/comp_algorithm` | 63 ms |
| `getprop <one property>` | 55 ms |
| `printf` (an external binary on Android, not a builtin) | 40 ms |

The old script formatted every log line as `printf "%s\n" "$(printf …)"` — three
forks per line — and looked up three properties separately. Replacing those with
builtins (`case`, parameter expansion, one `getprop` dump) and reading the two
`/proc` entries once each gave:

| | before | after |
|---|---|---|
| kernel already has the algorithms | 1013 ms, 7 modules | **701 ms, 2 modules** |
| kernel lacks them (module needed) | 1013 ms, 7 modules | **906 ms, 7 modules** |

Median of three warm runs each on the same device. The second row still loads
everything; it gained only the shell-side savings, which is why it moved less.

## Install

Download `zram-lkm-<version>-arm64.zip` (all KMIs) or
`zram-lkm-<version>-<kmi>-arm64.zip` (single KMI) — for example
`zram-lkm-v0.1.4-arm64.zip` — flash it in KernelSU / APatch, reboot.

The module **only loads the modules** during `post-fs-data`; it does not touch
your zram configuration — see below for why.

Manual:

```sh
insmod lz4k-<kmi>.ko
insmod lz4kd-<kmi>.ko
insmod lz4k_oplus-<kmi>.ko

cat /sys/block/zram0/comp_algorithm
# lzo lzo-rle [lz4] lz4hc zstd deflate lz4k lz4kd lz4k_oplus
```

## Switching algorithms

**Switching `comp_algorithm` resets zram0 and discards its contents.** Android
normally uses zram0 as swap, so order matters:

```sh
SIZE=$(cat /sys/block/zram0/disksize)
swapoff /dev/block/zram0
echo lz4k > /sys/block/zram0/comp_algorithm
echo "$SIZE" > /sys/block/zram0/disksize
mkswap /dev/block/zram0
swapon /dev/block/zram0
```

To switch at boot, drop a `zram_lkm.conf` in the module directory:

```sh
ALGO=lz4k_oplus
AUTO_SWITCH=1
```

`AUTO_SWITCH=0` by default. Switching during boot throws away pages already in
swap, which is a real risk on a memory-constrained device, so the timing is
left to you.

## Choosing an algorithm

There is no universal winner; it depends on the workload.

| Situation | Suggestion |
|-----------|------------|
| Small RAM, want ratio | `lz4kd` (delta variant, cheaper on similar pages) |
| Latency-sensitive (games, foreground UI) | `lzo-rle` (built in, fastest) |
| Middle ground | `lz4k` / `lz4k_oplus` |

Measured on one device (`Redmi Pad 2410CRP4CG`, `SM7675`, vendor kernel
`6.1.138-android14-11-g0c3d559bcd85`):
60 MB of real `.so` files written to a scratch zram device.

| Algorithm | Write | Read | Compressed (of 63.11 MB) |
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

One machine, one run. Repeating it on the same device moved writes by up to
20% and reads by up to 50%, so read these as orders of magnitude: the lz4
family is interchangeable within that noise, while the gaps to
`lz4hc`/`zstdn` and again to `842` are real. Ignore the ranking inside a family
and compare families.

Measure it on your own device and your own data — every ratio published
elsewhere was measured on somebody else's. The module ships a script:

```sh
sh /data/adb/modules/zram_lkm/zram-bench.sh
```

It rebuilds zram0 once per available algorithm, writes a sample (half repeated
text, half random bytes, which is closer to real usage than either extreme),
and reports compression ratio and write time per algorithm. It saves and
restores your disksize, algorithm and swap state afterwards.

Or read the numbers directly:

```sh
grep -E 'orig_data_size|compr_data_size' /sys/block/zram0/mm_stat
```

Field 1 is original size and field 2 is compressed size; their ratio is the
real compression ratio.

## What else could be a module, and what cannot

Worth separating the three cases, because "can I add X with a module?" has
three different answers:

| Kind | Example | Can a module do it? |
|------|---------|---------------------|
| Algorithm registration | `lz4k`, `lz4kd`, `842` | **Yes** — open namespace behind `crypto_register_alg()` |
| Whole driver, when the kernel has it as `=m` | `zram`, `zsmalloc` | **Yes** — ship your own `.ko`, but you must unload the vendor's first |
| Compile-time code path | `ZRAM_WRITEBACK`, `ZRAM_MULTI_COMP`, `ZRAM_RECOMPRESS` | **No** for the builtin `zram`; only reachable via the row above |

The third row is why the second exists. On a kernel with `CONFIG_ZRAM=y` the
writeback and multi-compress paths were never compiled and no module can conjure
them. On a kernel with `CONFIG_ZRAM=m` you can build your own zram.ko that has
them, at the cost of swapping out the system's swap backend.

Not implemented here, deliberately:

- **A custom `zram.ko` with `MULTI_COMP` / `RECOMPRESS`.** The win is real
  (per-page choosing between a fast and a dense compressor, and re-compressing
  cold pages in place), but the failure mode is losing swap on a device you
  may not be able to reboot cleanly. That belongs behind an explicit opt-in,
  not in a default package.
- **A custom `zsmalloc.ko`.** Same reasoning; the only feature worth having is
  `ZSMALLOC_STAT` for observability, which does not justify replacing the
  allocator that holds every compressed page.
- **`842`.** `CONFIG_CRYPTO_842` is absent on typical vendor kernels and the
  algorithm is built for hardware accelerators; on zram it loses to lz4 on both
  ratio and speed. Adding it would be a checkbox, not a feature.

Algorithm registration is the one row where the answer is unambiguously yes,
which is why this project stays in that row.

## Supported KMI

| KMI | Kernel |
|-----|--------|
| `android12-5.10` | 5.10 |
| `android13-5.10` | 5.10 |
| `android13-5.15` | 5.15 |
| `android14-5.15` | 5.15 |
| `android14-6.1` | 6.1 |
| `android15-6.6` | 6.6 |
| `android16-6.12` | 6.12 |

**arm64 only.**

## Going further: replacing zram.ko itself

If your device has `CONFIG_ZRAM=m` — many vendor kernels do — then zram is a
module too, and you can ship your **own** zram.ko:

```sh
swapoff /dev/block/zram0
rmmod zram
insmod /data/adb/modules/zram_lkm/zram.ko
# reconfigure
```

That reaches features the kernel never compiled in:

- `ZRAM_MULTI_COMP` (multiple compression streams, 6.4+)
- `ZRAM_RECOMPRESS` (writeback + recompress, 6.6+)
- newer zram bug fixes

**This is materially riskier**: you are replacing the system's swap backend. A
mismatched zram.ko means no swap at best and OOM at worst. This project does
**not** do it by default; the section exists so the option is documented.

Check the prerequisite:

```sh
zcat /proc/config.gz | grep -E '^CONFIG_ZRAM=|^CONFIG_ZSMALLOC='
# CONFIG_ZRAM=m        ← replaceable
# CONFIG_ZRAM=y        ← built in, cannot replace
```

## Build and release

Two workflows, deliberately separate:

| Workflow | Trigger | Publishes? |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | push to `main`, pull request, manual | No — artifacts only. Builds **one** KMI by default (`android14-6.1`); pass `full_matrix: true` for all seven |
| [`release.yml`](.github/workflows/release.yml) | tag `vX.Y.Z`, manual with a tag | Yes — **pre-release only** |

Both call the reusable [`build.yml`](.github/workflows/build.yml), which only
compiles and packages. A green CI check therefore can never put an artifact in
front of users, and every release corresponds to a tag someone chose.

```sh
git tag v0.1.0
git push origin v0.1.0
```

### Module layout

```
module/
├── module.prop        metadata
├── customize.sh       install-time checks and messages
├── post-fs-data.sh    insmod the per-KMI .ko (early, see its header for why)
├── service.sh         late_start: appends a state snapshot to the log
├── uninstall.sh       cleans up; deliberately does not rmmod
└── action.sh          the Action button: loaded modules, crypto list, live comp_algorithm
```

The `.ko` files live in the module's own `ko/` directory and are insmodded from
there. They are **not** placed under `system/lib/modules`: KernelSU only mounts
`system/` when a metamodule is installed, so that layout silently requires
something the user may not have.

## Sources and licensing

The algorithms come from the kernel-tree patches in
[SukiSU_patch](https://github.com/Pixel-Tent/SukiSU_patch) /
[ABK](https://github.com/cachiusa/AnyKernel3); this project turns them into
out-of-tree modules (adding `MODULE_ALIAS_CRYPTO`, tidying includes, writing
standalone Makefiles).

| Component | Origin | License |
|-----------|--------|---------|
| `lz4k` / `lz4kd` | Huawei Technologies | GPL-2.0 |
| `lz4k_oplus` | OPPO branch | GPL-2.0 |
| `extra/kallrecon/` | [Dere3046/KallRecon](https://github.com/Dere3046/KallRecon) | GPL-2.0 |

**GPL-2.0 requires source for binaries.** Every release carries
`source-<tag>.tar.gz`, the exact tree the `.ko` files were built from.

**Disclaimer**: loading a kernel module runs kernel code with full privilege,
and switching the ZRAM compressor discards data already compressed on that
device. Keep a fastboot / recovery path available.