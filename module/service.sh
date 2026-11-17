#!/system/bin/sh
# service.sh - late_start 阶段补一次状态快照
#
# 加载已经在 post-fs-data.sh 做完了；这里非阻塞地再记一笔，用来排查
# 「insmod 成功但算法没出现在列表里」这类问题。

MODDIR=${0%/*}
# 与 post-fs-data.sh 一致：日志在模块目录（root-only），不放 /data/local/tmp
LOG="$MODDIR/zram_lkm.log"

sleep 20
{
    echo "--- late check $(date) ---"
    echo "loaded modules:"
    lsmod 2>/dev/null | grep -E 'lz4k|lz4kd|lz4hc|842|zstdn|zstdp' || echo "  (none)"
    echo "zram0 comp_algorithm:"
    cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "  (no zram0)"
} >> "$LOG" 2>&1
