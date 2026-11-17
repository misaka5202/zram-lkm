## v0.1.5

`versionCode` 20261120.

### Fixed

**A decompression overflow in `lz4k_oplus`.** The small-literal fast path copied
`NR_COPY_MIN` (32) bytes without ever checking the *destination* capacity, while
the large-literal branch right below it did. A crafted compressed stream — zram
decompresses data from the backing store, so this is attacker-reachable, the same
surface as the two upstream 842 fixes already applied here — could write past the
vmalloc output buffer by up to ~31 bytes. Both branches now carry the destination
check the sibling Huawei decoder (`extra/lz4k/lz4k_decode.c`) has always had.

**A NULL dereference on malformed input.** `get_size()` returns NULL when the
extended length runs past the end of the input; both call sites passed it straight
into `literal_decompress()`, which dereferences it immediately. The entry point also
gained the non-NULL / minimum-length checks the Huawei decoder performs. Verified
by replicating the branch arithmetic: `dest_at=63, lit=1` overflowed before and is
exactly legal after.

**Log writes through a world-writable path.** `/data/local/tmp/zram_lkm.log` (and
the `zram-bench` work directory) were truncated and appended by root scripts with no
symlink check, while `/data/local/tmp` is writable by any app — so a planted symlink
made root truncate or append an arbitrary file. Logs moved under `/data/adb`
(root-only); the old location is migrated once as `.old`, and if it is a symlink it
is deleted rather than followed. `zram-bench` moved to `/data/adb/zram-bench` with an
explicit `-L` refusal.

**Workflow input injection.** `release.yml` interpolated `${{ inputs.tag }}` into a
`run:` block, where Actions substitutes text *before* the shell parses it: a tag
containing `"`, `;` or `$( )` escaped the quoting and ran arbitrary commands on the
runner with `contents: write`. The value now arrives via `env`, plus an anchored
`^v[0-9]+\.[0-9]+\.[0-9]+(-…)?$` whitelist and a line-count check (otherwise grep
matches per line and `v1.2.3\n<evil>` passes on its first line).

**A stale instruction cache on the inline hook.** `zram_list` fills its trampoline
with ordinary stores into an executable vmalloc page; on arm64 the icache and dcache
are not coherent, and `aarch64_insn_patch_text_nosync` only cleans the one target
instruction, never the trampoline. Another CPU branching there could fetch stale
bytes. `flush_icache_range()` now runs over the trampoline before the entry is
patched.

**Corrupted diagnostic strings.** Two messages in `zram_list_main.c` still contained
a mangled `'+ BS + 'n` where `\n` belonged (leftover from an earlier scripted edit);
they printed that literal instead of a newline.

### Changed

**Package names carry the version.** Artifacts are now
`zram-lkm-<version>-arm64.zip`, `zram-lkm-<version>-<kmi>-arm64.zip` and
`source-<version>.tar.gz` — previously every download was named identically and you
could not tell which build you had. The version is read from `module.prop`, so a
release cannot silently produce the previous version's filenames.

---

完整记录见 [CHANGELOG.md](CHANGELOG.md)。