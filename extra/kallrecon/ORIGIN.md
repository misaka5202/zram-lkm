# ORIGIN — where extra/kallrecon/ comes from

Vendored from **Dere3046/KallRecon**  
<https://github.com/Dere3046/KallRecon> — "reconstruct kallsyms on ARM64 GKI,
depends only on `sprint_symbol`". Licensed GPL-2.0.

Upstream `lib/` maps to `extra/kallrecon/`:

| upstream | here |
|---|---|
| `lib/*.c`, `lib/*.h`, `lib/anchor.S` | `extra/kallrecon/` |

Not vendored: `lib/raana/` — KallRecon's optional runtime helper, not needed for
the layout probe this module uses.

The files are byte-for-byte identical to upstream `lib/`; verified against the
blob hashes of `core.c`, `discover.c` and `access.c`. Last checked against
upstream `cec011bc` (2026-10-22).

For the resolver's behaviour and cost, see the README section
"Where the pointer types come from" / 「指针类型从哪来」.
