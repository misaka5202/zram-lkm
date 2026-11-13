#!/system/bin/sh
# 开机早期加载 zram 压缩算法模块。
#
# 设计原则：**加载模块**和**启用算法**是两件事，这里只做前者。
#
# 原因：切换 /sys/block/zram0/comp_algorithm 会重置该 zram 设备（现有内容
# 丢失），而 Android 通常把 zram0 当 swap 用。开机阶段自动切换会清掉 swap
# 里的页，在内存紧张时有实际风险。所以默认只加载模块，等系统跑起来后由
# 用户自己（Scene / sysfs）决定何时切换。
#
# 想开机自动切换的话，在模块目录放一个 zram_lkm.conf：
#     ALGO=lz4k_oplus
#     AUTO_SWITCH=1
# 只有 AUTO_SWITCH=1 才会执行切换。

MODDIR=${0%/*}
LOG="/data/local/tmp/zram_lkm.log"
CONF="$MODDIR/zram_lkm.conf"

: > "$LOG"
echo "=== zram_lkm $(date) ===" >> "$LOG"
echo "kernel: $(uname -r)" >> "$LOG"

for ko in "$MODDIR"/system/lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    name=$(basename "$ko")
    if out=$(insmod "$ko" 2>&1); then
        echo "[OK]   $name" >> "$LOG"
    else
        echo "[FAIL] $name: $out" >> "$LOG"
    fi
done

echo "--- loaded ---" >> "$LOG"
lsmod 2>/dev/null | grep -E 'lz4k|lz4kd|zstdp' >> "$LOG"

echo "--- zram0 comp_algorithm ---" >> "$LOG"
cat /sys/block/zram0/comp_algorithm 2>/dev/null >> "$LOG"

# ---- 可选：自动切换算法 ----
ALGO=""
AUTO_SWITCH="0"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

if [ "$AUTO_SWITCH" = "1" ] && [ -n "$ALGO" ]; then
    echo "--- 自动切换算法到 $ALGO ---" >> "$LOG"
    if ! grep -qw "$ALGO" /sys/block/zram0/comp_algorithm 2>/dev/null; then
        echo "[SKIP] zram0 不认识 $ALGO（模块可能没加载成功）" >> "$LOG"
    else
        # 记录当前 swap 状态和大小，切完恢复
        SWAPSIZE=$(cat /sys/block/zram0/disksize 2>/dev/null)
        WAS_SWAP=0
        grep -q '^/dev/block/zram0' /proc/swaps 2>/dev/null && WAS_SWAP=1

        [ "$WAS_SWAP" = "1" ] && swapoff /dev/block/zram0 2>/dev/null
        if echo "$ALGO" > /sys/block/zram0/comp_algorithm 2>>"$LOG"; then
            echo "[OK]   已切到 $ALGO" >> "$LOG"
            [ -n "$SWAPSIZE" ] && echo "$SWAPSIZE" > /sys/block/zram0/disksize 2>/dev/null
            [ "$WAS_SWAP" = "1" ] && { mkswap /dev/block/zram0 >/dev/null 2>&1; swapon /dev/block/zram0 2>/dev/null; }
        else
            echo "[FAIL] 切换 $ALGO 失败" >> "$LOG"
        fi
    fi
fi

echo "=== done ===" >> "$LOG"