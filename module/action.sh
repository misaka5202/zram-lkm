#!/system/bin/sh
# action.sh - KernelSU 模块页「操作」按钮
#
# 一句话回答两件事：算法装上了吗？列表里能看见吗？
#
# 文案走 i18n.sh，语言按系统属性判定，默认英文。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
LOG=/data/local/tmp/zram_lkm.log

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

echo "$M_A_LOG"
tail -20 "$LOG" 2>/dev/null || echo "$M_A_NO_LOG"