#!/usr/bin/env bash
# check-i18n.sh - 检查 module/i18n.sh 的语言覆盖是否完整
#
# 为什么要静态查：英文块是基线，zh/ja 只是覆盖其中的一部分。缺翻译不会报错，
# 只会静默回落到英文 —— 也就是说这类问题在真机上永远暴露不出来，只能查。
#
# 查四件事：
#   1. 脚本用到了、但英文块里没有定义的键   → 真 bug，会显示空白
#   2. 英文有、中文没有的键                 → 中文设备上显示英文
#   3. 英文有、日文没有的键                 → 日文设备上显示英文
#   4. 英文块里定义了、但没有脚本使用的键   → 死文案，改脚本后会腐烂
#
# 用法：
#   scripts/check-i18n.sh          # 有任何问题就退出码 1
#   scripts/check-i18n.sh --warn   # 只报告，不失败
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
I18N="$ROOT/module/i18n.sh"
STRICT=1
[ "${1:-}" = "--warn" ] && STRICT=0

[ -f "$I18N" ] || { echo "找不到 $I18N" >&2; exit 2; }

keys() { sed 's/^[[:space:]]*//' | grep -oE '^M_[A-Z0-9_]+=' | tr -d '=' | sort -u; }

# 英文基线是唯一定义在 case 之外的部分（顶格）
EN=$(grep -oE '^M_[A-Z0-9_]+=' "$I18N" | tr -d '=' | sort -u)
# zh / ja 是 case 分支里缩进定义的
ZH=$(sed -n '/^zh)/,/^ja)/p' "$I18N" | keys)
JA=$(sed -n '/^ja)/,/^esac/p'  "$I18N" | keys)

USED=$(
    for f in "$ROOT"/module/*.sh; do
        [ "$(basename "$f")" = "i18n.sh" ] && continue
        grep -oE 'M_[A-Z0-9_]+' "$f"
    done | sort -u
)

com()   { comm -23 <(printf '%s\n' "$1") <(printf '%s\n' "$2"); }
n_of()  { printf '%s\n' "$1" | grep -c . ; }

fail=0
report() {
    local label="$1" list="$2" hard="$3"
    [ -z "$list" ] && return 0
    echo "$label"
    printf '%s\n' "$list" | sed 's/^/    /'
    [ "$hard" = "hard" ] && fail=1
}

echo "键数量: en=$(n_of "$EN")  zh=$(n_of "$ZH")  ja=$(n_of "$JA")  脚本引用=$(n_of "$USED")"

report "脚本引用了、但英文块没有定义的键（会显示空白）:" "$(com "$USED" "$EN")" hard
report "英文有、中文没有（中文设备上会显示英文）:"        "$(com "$EN" "$ZH")"   soft
report "英文有、日文没有（日文设备上会显示英文）:"        "$(com "$EN" "$JA")"   soft
report "定义了但没有任何脚本使用:"                        "$(com "$EN" "$USED")" soft

# 中文块里出现、英文块里没有的键同样是错（英文是基线，不该被语言块补充）
report "中文有、英文没有（基线漏定义）:" "$(com "$ZH" "$EN")" hard
report "日文有、英文没有（基线漏定义）:" "$(com "$JA" "$EN")" hard

if [ "$fail" -eq 0 ] && [ "$STRICT" -eq 0 ]; then
    echo "（--warn 模式：以上均不判失败）"
fi

if [ "$fail" -ne 0 ]; then
    echo "发现硬错误：脚本引用的键必须在英文块里定义"
    exit 1
fi

if [ "$STRICT" -eq 1 ]; then
    hard_asym=$( {
        com "$EN" "$ZH"; com "$EN" "$JA"; com "$USED" "$EN"; com "$EN" "$USED"
        com "$ZH" "$EN"; com "$JA" "$EN"
    } )
    if [ -n "$hard_asym" ]; then
        echo "三种语言不完全对齐（见上）"
        exit 1
    fi
fi

echo "OK：三种语言完全对齐，没有死文案"
exit 0