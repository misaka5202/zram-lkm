#!/system/bin/sh
# 平台是 Magisk/KernelSU：模块在 post-fs-data 阶段已加载完成，这里只补一次
# 状态输出，便于排查「insmod 成功但算法没出现」这类问题。
MODDIR=${0%/*}
LOG="/data/local/tmp/zram_lkm.log"

sleep 20
{
    echo "--- late check $(date) ---"
    echo "loaded modules:"
    lsmod 2>/dev/null | grep -E 'lz4k|lz4kd|lz4hc|842|zstdp' || echo "  (none)"
    echo "zram0 comp_algorithm:"
    cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "  (no zram0)"
} >> "$LOG" 2>&1
