# ZRAM LKM

**Extend ZRAM compression algorithms on a stock Android GKI kernel with loadable modules — no kernel rebuild, no boot image flashing.**

[中文说明](docs/README.zh.md) · [Releases](../../releases/latest)

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

## Install

Download `zram-lkm-arm64.zip` (all KMIs) or `zram-lkm-<kmi>-arm64.zip` (single
KMI), flash it in KernelSU / APatch, reboot.

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

**GPL-2.0 requires source for binaries.** Every release carries
`source-<tag>.tar.gz`, the exact tree the `.ko` files were built from.

**Disclaimer**: loading a kernel module runs kernel code with full privilege,
and switching the ZRAM compressor discards data already compressed on that
device. Keep a fastboot / recovery path available.