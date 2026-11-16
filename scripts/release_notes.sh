#!/bin/sh
# 生成 Release 正文。
#
# 格式参考 KernelSU 的 release（v3.3.1）：
#
#     vX.Y.Z
#
#     ## What's Changed
#     * 条目
#
#     ## Supported kernels
#     | 表格 |
#
#     **Full Changelog**: https://.../compare/vPREV...vCUR
#
# 中文段落放在英文之后（GitHub 不按语言分发正文），中文小节标题翻成英文，
# 避免正文出现两套标题体系。
#
# 用法: release_notes.sh <tag> <dist 目录> [仓库 root]
#
# 注意：本仓库的 zip 文件名不带版本号（zram-lkm-arm64.zip），所以 tag 必须
# 由调用方传入，不能从产物名推。
set -eu

TAG="${1:?用法: release_notes.sh <tag> <dist> [root]}"
DIST="${2:-dist}"
ROOT="${3:-.}"

REPO_SLUG="${REPO_SLUG:-misaka5202/zram-lkm}"
PKG_PREFIX="${PKG_PREFIX:-zram-lkm}"
MODULE_TITLE="${MODULE_TITLE:-ZRAM LKM}"

# 上一个版本：从 git tag 取按版本排序后的前一个。
#
# 不能从 CHANGELOG 里取「当前版本之后的下一个标题」—— 本仓库的 CHANGELOG
# 不是严格倒序（v0.1.4 后面跟的是 v0.1.0，再后面才是 v0.1.3），那样会算错。
PREV=""
if command -v git >/dev/null 2>&1; then
    PREV=$(git -C "$ROOT" tag --sort=-v:refname 2>/dev/null            | awk -v v="$TAG" 'prev { print; exit } $0 == v { prev = 1 }')
fi

# 切出指定版本条目并转成 KernelSU 风格：小节标题保留，"### 修复" 等翻成英文，
# 列表符号统一 "*"。
list_items() {
    _f=$1
    [ -f "$_f" ] || return 0
    awk -v v="$TAG" '
        !started && $0 ~ "^## " v "([[:space:]]|$)" { started = 1; next }
        started && /^## / { exit }
        !started { next }
        /^---[[:space:]]*$/ { next }
        /^- / { sub(/^- /, "* "); print; next }
        { print }
    ' "$_f" | sed -e 's/^### 修复$/### Fixed/' \
               -e 's/^### 新增$/### Added/' \
               -e 's/^### 变更$/### Changed/' \
               -e 's/^### 版本变体$/### Version variants/' \
               -e 's/^### 验证$/### Verification/' \
               -e 's/^### 已知问题$/### Known issues/' \
        | cat -s
}

# ---------------------------------------------------------------------------
# 正文
# ---------------------------------------------------------------------------
echo "$TAG"
echo ''
echo "## What's Changed"
echo ''
list_items "$ROOT/docs/CHANGELOG.md"

echo ''
echo '## Supported kernels'
echo ''
echo '| File | Android / kernel |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-*-arm64*.zip; do
    [ -f "$z" ] || continue
    n=$(basename "$z")
    kmi=$(echo "$n" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -1)
    [ -n "$kmi" ] || continue
    and=$(echo "$kmi" | sed -e 's/^android//' -e 's/-.*$//')
    kver=$(echo "$kmi" | sed -e 's/^android[0-9]*-//')
    echo "| \`$n\` | Android $and / $kver |"
done

echo ''
echo '| File | Note |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | All kernels in one package, picks the right one at boot |"
done

echo '| `source-*.tar.gz` | Source snapshot (GPL-2.0) |'

cat <<'NOTE'

The `.ko` files are not signed. On kernels built with
`CONFIG_MODULE_SIG_FORCE=y` they cannot be inserted at all, and `insmod`
reports `module verification failed`. Check with:

```sh
zcat /proc/config.gz | grep CONFIG_MODULE_SIG_FORCE
```

If a module fails to load, press the **Action** button on the KernelSU module
page and include its output in the issue.
NOTE

# ---------------------------------------------------------------------------
# 中文
# ---------------------------------------------------------------------------
echo ''
echo '---'
echo ''
echo '## 变更内容'
echo ''
list_items "$ROOT/docs/CHANGELOG.zh-CN.md"

echo ''
echo '## 支持的内核'
echo ''
echo '| 文件 | Android / 内核 |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-*-arm64*.zip; do
    [ -f "$z" ] || continue
    n=$(basename "$z")
    kmi=$(echo "$n" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -1)
    [ -n "$kmi" ] || continue
    and=$(echo "$kmi" | sed -e 's/^android//' -e 's/-.*$//')
    kver=$(echo "$kmi" | sed -e 's/^android[0-9]*-//')
    echo "| \`$n\` | Android $and / $kver |"
done

echo ''
echo '| 文件 | 说明 |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | 全 KMI 合并包，开机自动选择对应的一份 |"
done

echo '| `source-*.tar.gz` | 源码快照（GPL-2.0） |'

cat <<'NOTE'

`.ko` 未签名。内核若编译时开了 `CONFIG_MODULE_SIG_FORCE=y`，这些模块**完全装不上**，
`insmod` 会报 `module verification failed`。确认方式：

```sh
zcat /proc/config.gz | grep CONFIG_MODULE_SIG_FORCE
```

模块装不上时，请点 KernelSU 模块页的**「操作」**按钮，把输出贴进 issue。
NOTE

# ---------------------------------------------------------------------------
# Full Changelog
# ---------------------------------------------------------------------------
echo ''
if [ -n "$PREV" ]; then
    echo "**Full Changelog**: https://github.com/$REPO_SLUG/compare/$PREV...$TAG"
else
    echo "**Full Changelog**: https://github.com/$REPO_SLUG/commits/$TAG"
fi
