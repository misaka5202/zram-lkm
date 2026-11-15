# How many zram compression types are there?

The short answer: **as many as the crypto API knows about** — zram has no list
of its own that it enforces.

## Why there is no fixed number

In `drivers/block/zram/zcomp.c`:

```c
bool zcomp_available_algorithm(const char *comp)
{
	return crypto_has_comp(comp, 0, 0) == 1;
}
```

That single call is the whole validation. Writing a name to
`/sys/block/zramN/comp_algorithm` asks the crypto API whether such a
`compression` algorithm is registered. If it is, zram accepts it.

The `backends[]` array in the same file is easy to mistake for a whitelist:

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

It is only read by `zcomp_available_show()`, which prints the contents of
`comp_algorithm` and brackets the active one. An algorithm absent from that
array works perfectly but never appears in the listing — which is exactly what
happens to every algorithm this project ships. It is also why `deflate`, present
in many vendor kernels, never shows up in that file.

## What upstream ships

Seven algorithms have a `cra_name` a zram disk can use, all from `crypto/`:

| # | `cra_name` | `cra_driver_name` | Kconfig gate |
|---|---|---|---|
| 1 | `842` | `842-generic` | `CONFIG_CRYPTO_842` |
| 2 | `deflate` | `deflate-generic` | `CONFIG_CRYPTO_DEFLATE` |
| 3 | `lz4` | `lz4-generic` | `CONFIG_CRYPTO_LZ4` |
| 4 | `lz4hc` | `lz4hc-generic` | `CONFIG_CRYPTO_LZ4HC` |
| 5 | `lzo` | `lzo-generic` | `CONFIG_CRYPTO_LZO` |
| 6 | `lzo-rle` | `lzo-rle-generic` | `CONFIG_CRYPTO_LZO` |
| 7 | `zstd` | `zstd-generic` | `CONFIG_CRYPTO_ZSTD` |

Anything else is either an out-of-tree codec (the lz4k family, and dozens of
vendor variants) or something nobody has wrapped yet.

## What this project adds

| Module | Name | Needs the kernel to export the codec? |
|---|---|---|
| `lz4k` | `lz4k` | no — the codec is compiled into the module |
| `lz4kd` | `lz4kd` | no — same |
| `lz4k_oplus` | `lz4k_oplus` | no — same |
| `lz4hc` | `lz4hc` | yes — reuses `LZ4_compress_HC` / `LZ4_decompress_safe` |
| `842` | `842` | no — the codec is not built at all, so the module carries lib/842 |
| `zstdn` / `zstdn_o` | `zstdn`, `zstdn_o` | yes — reuses the kernel's exported zstd single-pass API at level 1 |

`lz4hc` is the interesting case. Vendor kernels commonly build the LZ4HC codec
(`CONFIG_LZ4HC_COMPRESS=y`) but trim its crypto registration
(`# CONFIG_CRYPTO_LZ4HC is not set`), because the registration is what a GKI ABI
check trips over. The codec functions are `EXPORT_SYMBOL`ed, so the module only
has to register a `crypto_alg` — no codec copy, a few dozen lines, and the
resulting `.ko` is a couple hundred kilobytes instead of megabytes.

That is the same situation user namespaces were in: the implementation is
already in the kernel, and only the glue that publishes it was compiled out.

## Checking a device

```sh
# what the kernel actually exposes
grep -E '^name|^driver' /proc/crypto | paste - - | grep -B1 -A0 -i comp

# simpler: ask the crypto API by trying to use the name
echo lz4hc > /sys/block/zram0/comp_algorithm && echo worked
```

`/proc/crypto` lists every registered transform with its type; the ones with
`type : compression` are zram candidates.

## Which to use

Ratio and speed are device- and workload-specific, so this project ships
`scripts/zram-bench.sh` rather than a table of claims. As a rough ordering on
ARM64, from fastest to best-ratio: `lz4` → `lz4k` → `lz4hc` (`lz4hc_level` 3-16)
→ `zstd`. `lzo-rle` sits near `lz4k` on ratio with lower CPU. `lz4kd` and
`lz4k_oplus` are worth trying when your pages are similar to each other, which
is the common case for zram swap.

## Making them appear in the list

Everything above works, but `comp_algorithm` never printed any of it. That file
comes from `zcomp_available_show()` walking a `static const char * const
backends[]` array compiled into zram.ko -- fixed at build time. A module can
register whatever it likes; the list will not change, and users read that list
as the answer to "what can I pick".

`zram_list.ko` fixes the view rather than the data, which is the same move as
the namespace work in droidspaces-lkm: redirect the one function that produces
the published view.

- `zcomp_available_show()` is a global symbol in zram.ko, called only from the
  `comp_algorithm` sysfs show handler, so one hook covers every zram device.
- The hook is a 4-byte `b` over the first instruction; the displaced
  instruction plus an absolute jump live in a page allocated next to the
  target. It cannot be a direct branch to the module: with VA_BITS=39 the
  general vmalloc area is tens of GB from kernel text (measured ~95GB here) and
  `b` reaches 128MB.
- The replacement calls the original through the trampoline for the built-in
  list, then appends any of the ten names that `crypto_has_comp()` reports --
  the same question zram itself asks, so nothing is hardcoded about which
  modules happen to be loaded.

Two deliberate refusals: if no page is available within reach, or the first
instruction is PC-relative and would need relocation, the module does not hook
and says why. A wrong trampoline writes garbage into live kernel text.

**Ships in the module zip and loads at boot.** Tools that read
`/sys/block/zram0/comp_algorithm` for their algorithm picker -- Scene, for
instance, which has no hardcoded compressor names and parses that file directly
-- therefore see the module-provided algorithms too.

If `zram` is not up yet when this module loads, it retries every 3 s for up to
about a minute instead of giving up, since module load order is not guaranteed.
When hooking fails it stays out of the way and the file remains untouched.
`rmmod zram_list` restores the original bytes.
