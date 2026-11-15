#!/system/bin/sh
# action.sh - KernelSU 模块页「操作」按钮
#
# 一句话回答两件事：算法装上了吗？列表里能看见吗？

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
LOG=/data/local/tmp/zram_lkm.log

echo "=== ZRAM LKM ==="
echo "内核    : $(uname -r)"
echo "模块版本: $(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
echo

echo "=== 已加载的算法模块 ==="
if lsmod | grep -qE '^(lz4k|lz4kd|lz4hc|842|zram_list) '; then
    lsmod | grep -E '^(lz4k|lz4kd|lz4k_oplus|lz4hc|842|zstdn|zstdp|zram_list) '
else
    echo "未加载"
fi
echo

echo "=== crypto 已注册的 compression 算法 ==="
awk '/^name/ {n=$3} /^type/ {if ($3=="compression") print "  " n}' /proc/crypto 2>/dev/null | sort -u
echo

echo "=== zram0 的 comp_algorithm ==="
cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "  (没有 zram0)"
echo

echo "=== 提示 ==="
echo "  切换算法会重建 zram 内容（Android 上 zram0 通常是 swap）："
echo "    echo lz4k_oplus > /sys/block/zram0/comp_algorithm"
echo "  zram_list 只美化列表显示，不影响实际可用性。"
echo

echo "=== 日志（末尾 20 行）==="
tail -20 "$LOG" 2>/dev/null || echo "(无日志)"
