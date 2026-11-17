#!/system/bin/sh
# action.sh - KernelSU 模块页「操作」按钮
#
# 一句话回答两件事：算法装上了吗？列表里能看见吗？
#
# 文案走 i18n.sh，语言按系统属性判定，默认英文。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
LOG="$MODDIR/zram_lkm.log"

ZR_I18N="$MODDIR/i18n.sh"
[ -f "$ZR_I18N" ] || ZR_I18N=/data/adb/modules/zram_lkm/i18n.sh
if [ -f "$ZR_I18N" ]; then
    . "$ZR_I18N"
else
    M_TITLE="ZRAM LKM"
    M_A_LOADED="=== Loaded algorithm modules ==="
    M_A_NONE="none loaded"
    M_A_CRYPTO="=== compression algorithms registered in crypto ==="
    M_A_COMP="=== zram0 comp_algorithm ==="
    M_A_NO_ZRAM0="  (no zram0)"
    M_A_HINTS="=== Notes ==="
    M_A_HINT_SWITCH="  switching the algorithm rebuilds the zram contents (on Android zram0"
    M_A_HINT_SWITCH2="  is usually swap):"
    M_A_HINT_ZRAMLIST="  zram_list only prettifies the list display; it does not affect usability."
    M_A_LOG="=== Log (last 20 lines) ==="
    M_A_NO_LOG="(no log)"
fi

echo "=== $M_TITLE ==="
echo "$M_KERNEL$(uname -r)"
echo "$M_MODULE_VER$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
echo

echo "$M_A_LOADED"
if lsmod | grep -qE '^(lz4k|lz4kd|lz4hc|842|zram_list) '; then
    lsmod | grep -E '^(lz4k|lz4kd|lz4k_oplus|lz4hc|842|zstdn|zstdp|zram_list) '
else
    echo "$M_A_NONE"
fi
echo

echo "$M_A_CRYPTO"
awk '/^name/ {n=$3} /^type/ {if ($3=="compression") print "  " n}' /proc/crypto 2>/dev/null | sort -u
echo

echo "$M_A_COMP"
cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "$M_A_NO_ZRAM0"
echo

echo "$M_A_HINTS"
echo "$M_A_HINT_SWITCH"
[ -n "$M_A_HINT_SWITCH2" ] && echo "$M_A_HINT_SWITCH2"
echo "    echo lz4k_oplus > /sys/block/zram0/comp_algorithm"
echo "$M_A_HINT_ZRAMLIST"
echo

echo "$M_SEC_EXPORT"
# 构建期把每个 .ko 的未定义符号导成 ko/symcheck-<kmi>.txt。
# 这里拿清单查 /proc/kallsyms 的 __ksymtab_ 条目 —— 直接报出本内核缺哪些，
# 不依赖能读 dmesg（有些厂商内核上读不到，用户只看到笼统的 unknown symbol）。
_krel=$(uname -r)
_kandroid=$(echo "$_krel" | grep -oE 'android[0-9]+' | head -1)
_kmajor=$(echo "$_krel" | grep -oE '^[0-9]+[.][0-9]+' | head -1)
_kmi=""
[ -n "$_kandroid" ] && [ -n "$_kmajor" ] && _kmi="${_kandroid}-${_kmajor}"
# 兜底：post-fs-data.sh 开机时已把推导结果写进日志
if [ -z "$_kmi" ] && [ -f "$LOG" ]; then
    _kmi=$(grep -a 'kmi:' "$LOG" 2>/dev/null | tail -1 | sed 's/.*kmi:[[:space:]]*//' | tr -d ' \r')
    case "$_kmi" in android*) ;; *) _kmi="" ;; esac
fi
_sf="$MODDIR/ko/symcheck-${_kmi}.txt"
if [ -z "$_kmi" ]; then
    echo "  [--]   $M_EXPORT_NONE"
elif [ ! -f "$_sf" ]; then
    echo "  [--]   $(printf "$M_EXPORT_NOFILE" "$_kmi")"
else
    # /proc/kallsyms 只读一次：先抽一份导出符号名单（__ksymtab_ 后面的名字），
    # 再用 awk 单趟比对。逐符号 grep 在二十多万行的 kallsyms 上会卡死。
    _have=$(mktemp)
    grep -a '__ksymtab_' /proc/kallsyms 2>/dev/null \
        | sed 's/.*__ksymtab_//' | sort -u > "$_have"

    # 清单格式：每行一个符号；"# <模块名>" 是分组标记，不参与比对。
    # 计数和显示必须用同一个条件，否则会出现「报 0 个缺失却列出好几条」。
    _miss=$(awk '
        FNR == NR { have[$1] = 1; next }
        /^#/ { next }
        NF >= 1 && !($1 in have) { n++ }
        END { print n + 0 }
    ' "$_have" "$_sf" 2>/dev/null)
    _miss=${_miss:-0}

    if [ "$_miss" -eq 0 ]; then
        echo "  [OK]   $M_EXPORT_ALL_OK"
    else
        awk -v fmt="$M_EXPORT_MISS_ONE" '
            FNR == NR { have[$1] = 1; next }
            /^#/ { next }
            NF >= 1 && !($1 in have) { printf "  [SYM]  "; printf fmt "\n", $1, $1 }
        ' "$_have" "$_sf" 2>/dev/null
        echo "         $(printf "$M_EXPORT_MISS_HEAD" "$_miss")"
        echo "         $M_EXPORT_MISS_TAIL"
    fi
    rm -f "$_have"
fi
echo

echo "$M_A_LOG"
tail -20 "$LOG" 2>/dev/null || echo "$M_A_NO_LOG"