#!/bin/sh
# 生成 Release 正文 —— Keep-a-Changelog 风格，与 droidspaces-lkm v0.1.27 的
# release 页一致：
#
#     # Changelog
#
#     ## <X.Y.Z> - <YYYY-MM-DD>
#
#     <docs/CHANGELOG.md 中该版本的条目原文（### 分节）>
#
#     ---
#
#     Full history: [docs/CHANGELOG.md](<permalink>)
#
# 条目来自 docs/CHANGELOG.md 的 "## vX.Y.Z" 节，原样输出——正文即
# CHANGELOG，不再维护第二套说法。
#
# zram 的 CHANGELOG 标题是 "## vX.Y.Z"（无日期），这里规范化成
# "## X.Y.Z - <日期>"；日期取 $4，缺省为当前 UTC 日期。
#
# 用法: release_notes.sh <tag> <dist 目录> [仓库 root] [YYYY-MM-DD]
set -eu

# 去掉条目首尾的空行（cat -s 只能压缩中间的连续空行）
trim() {
    awk 'NF && !started { started = 1 }
         started        { buf[++n] = $0 }
         NF             { last = n }
         END { for (i = 1; i <= last; i++) print buf[i] }'
}

TAG="${1:?用法: release_notes.sh <tag> <dist> [root] [date]}"
DIST="${2:-dist}"
ROOT="${3:-.}"
DATE="${4:-$(date -u +%F)}"

REPO_SLUG="${REPO_SLUG:-misaka5202/zram-lkm}"

CL="$ROOT/docs/CHANGELOG.md"
[ -f "$CL" ] || { echo "::error::缺少 $CL" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 切当前版本条目：从 "## vX.Y.Z" 标题行开始，到下一个 "## " 前结束。
# 标题行丢弃（没有日期），由下面重新输出规范化后的 "## X.Y.Z - <日期>"。
# ---------------------------------------------------------------------------
ENTRY=$(awk -v v="$TAG" '
    $0 ~ "^## " v "([[:space:]]|$)" { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$CL" | cat -s | trim)

[ -n "$ENTRY" ] || {
    echo "::error::$CL 里没有 $TAG 的条目（标题形如 \"## $TAG\"）" >&2
    exit 1
}

echo '# Changelog'
echo
echo "## ${TAG#v} - $DATE"
echo
echo "$ENTRY"
echo
echo '---'
echo
echo "Full history: [docs/CHANGELOG.md](https://github.com/$REPO_SLUG/blob/main/docs/CHANGELOG.md)"
