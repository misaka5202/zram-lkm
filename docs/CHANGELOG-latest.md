## v0.1.6

`versionCode` 20261121。

### 变更

**KallRecon 成为首选解析器。** `extra/kallrecon/` 直接解析内核的 kallsyms 表，
符号解析不再以 kprobe 为前提：不要求 `register_kprobe`、不受 kprobe 黑名单限制
（`aarch64_insn_patch_text_nosync` 这类也能解析）、与 `kptr_restrict` 无关。
KallRecon 布局探测失败时仍回退到 kprobe 探测。五个解析符号的模块
（lz4hc / 842 / zstdn / zram_list 与解析器自身）统一走
`extra/compat/zram_symres.h`。

**`zram_list` 不再自带第二份解析实现。** 它的 `zl_lookup_probe` / `zl_lookup`
与 `zr_lookup_probe` / `zr_lookup` 逐字相同，现在一个入口服务全部五个模块。

### 验证

全 KMI 矩阵编译通过；6.1 产物的 `.symtab` 确认 `find_kallsyms_base` /
`kallrecon_klp` 已解析（不再是未定义符号），引擎确实链进去了。

---

完整记录见 [CHANGELOG.md](CHANGELOG.md)。
