# Changelog

[中文](CHANGELOG.zh-CN.md)

## About the version numbers

This project has **no stable release yet**. Everything published so far is a
GitHub pre-release (preview).

Early builds used `1.0.x`, but those numbers looked stable while only
"compiles and loads by hand on one device" had been verified. All of those
releases are deleted and numbering restarted at `0.1.0`.

`versionCode` is date-encoded (`v0.1.0` → `20261115`). The old `1.0.x` line used
small integers like `10001`–`10003`; continuing with small numbers would let the
KernelSU updater decide the new build is *older* and never push it. Date
encoding is monotonic by construction, so a version reset cannot move it
backwards.

## v0.1.4

`versionCode` 20261119.

### Fixed

**Runtime symbol resolution for `842`, `lz4hc`, `zstdn`.** Vendor kernels may
retain a function in `kallsyms` without exporting it; static references then
fail with `Unknown symbol` at `insmod`. Addresses are now resolved at init via a
kprobe on `kallsyms_lookup_name()` (`extra/compat/zram_symres.h`), and calls go
through function pointers marked `__nocfi` (`CONFIG_CFI_CLANG` rejects
unannotated indirect calls).

Modules now load on kernels that never exported these symbols.

**`uninstall.sh` message.** Now states that registered algorithms remain active
until the next reboot.

### Added

- `scripts/gen_symproto.py` — generates pointer prototypes from the running
  kernel's BTF; also reports which symbols a built `.ko` requires but the kernel
  does not export.
- Action button output lists the specific missing symbols for the current kernel.
- Japanese translation: 26/48 → 48/48 strings; `scripts/check-i18n.sh` wired into
  CI and fails on drift.

### Changed

- Loader skips modules for algorithms the kernel already provides.
- `post-fs-data` script: removed per-line process creation overhead (`printf` is
  an external binary on Android; the previous implementation forked three times
  per log line).

### Performance

| Condition | Before | After |
|---|---|---|
| Kernel supplies the algorithms | 1013 ms, 7 modules | 701 ms, 2 modules |
| Kernel lacks them | 1013 ms, 7 modules | 906 ms, 7 modules |

Per-module load cost 60–110 ms and 20–24 KB resident. Runtime throughput is
within the ±1.5% noise floor measured against a kernel with the codecs built in
(same device, alternating runs).

### Known issues

- A vendor kernel that registers its own `842` at `cra_priority 100` prevents the
  module's copy from being selected: it loads and registers but does not take
  over. Verify with `grep -A3 'name *: 842' /proc/crypto`.

## v0.1.0 — first tagged preview

`versionCode` 20261115.

Module packaging and installation were reworked; the algorithms themselves are
unchanged (still lz4k / lz4kd / lz4k_oplus / lz4hc / 842, plus zram_list).

- **`.ko` files no longer go into `system/lib/modules/`.** KernelSU only mounts
  `system/` when a metamodule is installed, so that layout silently assumed
  something the user may not have: without the metamodule, installing the zip
  did nothing at all. They now live in the module's own `ko/` directory and
  `post-fs-data.sh` insmods them from there.
- **CI and release are decoupled.** `ci.yml` only builds and leaves artifacts;
  `release.yml` runs only on a tag and forces `--prerelease`. A green CI run can
  no longer push an unverified build to users.
- Module layout follows the KernelSU convention: `MODDIR=${0%/*}`, no
  `set_perm*`, and a new `action.sh`.
- **The combined package loaded modules built for the wrong KMI.**
  `post-fs-data.sh` used to "insmod whatever is in `ko/`". That is fine for a
  single-KMI package, but the combined package carries 5 algorithms × 7 KMIs =
  35 `.ko` files and would try each one, including builds for other kernel
  versions. The KMI filter was dropped when the layout changed; it is back in
  the script, deriving the KMI from the kernel major version first and loading
  only the matching set.
- Fixed `842` failing to load: `module_param_named` sat in a header included by
  two translation units, producing two sysfs parameters with the same name, so
  the module failed with `-EEXIST` before init ever ran.
- **`zram_list` ate names out of the list.** The in-place filter wrote back with
  `scnprintf`, which appends a `\0` that lands exactly on the first byte of the
  next token — observed turning `lzo-rle` into an empty string. It now moves
  bytes and appends the terminator once at the end.
- Fixed `zram_list` only adding its own five names: the vendor's `zstdp` is
  registered but was equally invisible, and is now included. Conversely,
  `zstdn` / `zstdn_o` in the vendor's `backends[]` are not registered at all,
  so they are now filtered out instead of inviting users to pick an algorithm
  that does not exist.

## v0.1.3 — two upstream 842 decompression overflow fixes

`versionCode` 20261118. **Security fix, upgrade recommended.**

Auditing the vendored 842 codec showed the 6.1 copy is missing two upstream
fixes, and both defects land **exactly on the reason this module exists** — the
zram compression write-back path.

**1. index / short-data output overflow** (upstream `38ed7182f349`)

```c
if (size > p->olen)      // absent in our copy
    return -ENOSPC;
memcpy(p->out, &p->ostart[offset], size);
p->olen -= size;
```

The indexed copy writes 2/4/8 bytes and short-data writes up to 7, and neither
checks the caller's capacity. After writing past an undersized destination
buffer, `p->olen` is **unsigned** and underflows to a huge value, so every later
`olen` bounds check in the stream is defeated and the overrun continues. The
upstream commit notes it is reachable by tampering with compressed data on the
zram backing device; a KASAN kernel reports `vmalloc-out-of-bounds` in
`__do_index()` / `sw842_decompress()`.

**2. repeat template missing a full history block** (upstream `deb631649882`)

```c
if (p.out == out)              // old: only refuse when nothing was output
if (p.out - p.ostart < 8)      // new: require at least one full 8-byte block
```

repeat copies the preceding 8-byte output block. Short-data can produce as few
as 1–7 bytes, and an immediately following repeat then reads from **before the
start** of the output buffer — faulting depending on the mapping, or pulling
adjacent kernel memory into the decompressed result.

Both are applied locally and verified line by line against upstream master.
**Kernels 6.15 and earlier do not have these fixes**; only mainline does.

`CONFIG_CRYPTO_USER` is off on this device, so `AF_ALG` is unavailable and an
unprivileged process cannot feed data directly; the zram write-back path and
devices with `AF_ALG` enabled are still affected, so they are patched anyway.

## v0.1.2 — zstdn / zstdn_o added

`versionCode` 20261117.

These two names are OPPO/OnePlus house algorithms that `zram_list` had been
filtering out as "registered nowhere, dead entries". OnePlus 15 (sm8850) source
proves they are real: `vendor/oplus/kernel/mm/zstd_o/`, where `crypto_zstd.c`
registers `zstdn_o`, the comment says `replace zstdn -> zstdn_o`, and the only
difference from stock zstd is one line:

```c
#define ZSTD_DEF_LEVEL	1
```

Stock zstd runs level 3; this runs level 1 — compression ratio traded for
speed, which is the right trade on a swap device.

OPPO compiles the whole zstd stack (27 files) into their own module because they
build out of tree. This project does what it does for `lz4hc`: the kernel
already has the zstd codec built in and exports the one-shot API
(`zstd_get_params` / `zstd_cctx_workspace_bound` / `zstd_init_cctx` /
`zstd_compress_cctx` and the dctx counterparts), so only registration is needed
here, about 500 lines.

Both `zstdn` and `zstdn_o` are registered, because OPPO's own list
(`backends[]` says `zstdn`) and its registration (the module registers
`zstdn_o`) disagree, and either firmware may want either name.

Measured (32 MB mixed sample, this device, android14-6.1):

| Algorithm | Ratio | Time |
|---|---|---|
| zstdn | 1.96x | — |
| zstdn_o | 1.96x | 116ms |

After loading, `comp_algorithm` becomes:

```
lzo lzo-rle lz4 zstd lz4k zstdn zstdn_o [lz4k_oplus] lz4kd lz4hc 842
```

The vendor's two dead entries are now real algorithms.

## v0.1.1 — zram_list ships and autostarts

`versionCode` 20261116.

`zram_list` had been excluded from the package on the grounds that it "rewrites
kernel text and is unverified". It has since been verified repeatedly by hand
(it hooks a single function, `zcomp_available_show`, and gives up silently on
failure), and **not loading it means the algorithms this module provides never
appear in any UI that reads `comp_algorithm`** — including Scene, whose APK
contains no hardcoded compressor names and takes the list entirely from
`/sys/block/zram0/comp_algorithm`.

So:

- `zram_list` now ships and autostarts, in both the combined and single-KMI
  packages
- Loading no longer requires "zram already up": if it is missing it retries
  every 3 seconds for about a minute (module load order is not guaranteed, and
  giving up after one attempt used to mean a permanent failure when loading
  happened too early at boot)

Measured: after loading, `comp_algorithm` goes from
`lzo lzo-rle lz4 zstd lz4k zstdn zstdn_o [lz4k_oplus]`
to
`lzo lzo-rle lz4 zstd lz4k [lz4k_oplus] lz4kd lz4hc 842` —
the module's algorithms appear, and the vendor's unregistered `zstdn`/`zstdn_o`
are filtered out.