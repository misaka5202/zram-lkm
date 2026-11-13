# ZRAM LKM

**Extend ZRAM compression algorithms on a stock Android GKI kernel with loadable modules — no kernel rebuild, no boot image flashing.**

[中文说明](docs/README.zh.md) · [Releases](../../releases/latest)

---

Vendor kernels usually keep only `lzo-rle` for ZRAM, trimming every other
algorithm at build time to satisfy GKI ABI checks. This project packages those
algorithms as `.ko` files you `insmod` — and in fact they load *on demand* when
zram is asked to use them.

## Algorithms

| Module | Algorithm name | Origin | Versus lzo-rle |
|--------|---------------|--------|----------------|
| `lz4k` | `lz4k` | Huawei | better ratio, speed close to LZ4 |
| `lz4kd` | `lz4kd` | Huawei | delta variant, exploits page similarity |
| `lz4k_oplus` | `lz4k_oplus` | OPPO | OPPO's branch of LZ4K |

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

Measure it:

```sh
grep -E 'mem_used_total|compressed_data_size' /sys/block/zram0/mm_stat
```

Field 2 is compressed size and field 3 is original size; their ratio is the
real compression ratio.

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

## Build

CI builds inside the SukiSU DDK container, which carries the real `vmlinux`,
`Module.symvers` and matching clang per KMI:

```bash
bash scripts/build_modules.sh <kmi> /opt/ddk/kdir/<kmi> "$PWD" "$PWD/out"
```

Local builds need the matching kernel tree:

```bash
bash scripts/build_modules.sh android14-6.1 ~/kernel/common "$PWD" "$PWD/out" \
  LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld HOSTCC=clang HOSTLD=ld.lld O=out
```

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