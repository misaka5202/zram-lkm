#!/system/bin/sh
# 比较 zram 压缩算法的实际效果。
#
# 为什么需要它：网上关于"哪个算法压缩率高"的说法大多是别人的设备和别人的
# 数据。真正有意义的数字只能在自己设备、自己数据上量。
#
# 原理：zram 的 /sys/block/zram0/mm_stat 第 2 列是压缩后大小、第 3 列是原始
# 大小，比值就是实际压缩率；同时记录写入耗时粗略反映速度。
#
# 用法（需 root）：
#   sh zram-bench.sh                 # 用模块自带的测试数据
#   sh zram-bench.sh /path/to/data   # 用你自己的数据文件
#   SAMPLE_MB=64 sh zram-bench.sh    # 改样本大小
#
# 注意：会临时重建 zram0。脚本会先备份当前的 disksize / 算法 / swap 状态，
# 结束后尝试恢复；但仍建议在你能接受 swap 短暂不可用的情况下运行。

set -u

SAMPLE_MB="${SAMPLE_MB:-32}"
DATA_FILE="${1:-}"
# 工作目录放 /data/adb（root-only）而不是 /data/local/tmp：后者全局可写，
# 普通用户可预置符号链接，本脚本以 root 写入时变成任意文件覆写。
WORK="/data/adb/zram-bench"
LOG="$WORK/result.txt"

die() { echo "错误：$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "需要 root"
[ -e /sys/block/zram0 ] || die "没有 /sys/block/zram0（zram 未加载？）"

# 防符号链接：路径若是指向别处的链接，拒绝而不是顺着写
[ -L "$WORK" ] && die "$WORK 是符号链接，拒绝继续"
umask 077
mkdir -p "$WORK"

# ---- 备份当前状态 ----
ORIG_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr ' ' '\n' | sed -n 's/^\[\(.*\)\]$/\1/p')
ORIG_SIZE=$(cat /sys/block/zram0/disksize 2>/dev/null)
WAS_SWAP=0
grep -q '^/dev/block/zram0' /proc/swaps 2>/dev/null && WAS_SWAP=1

echo "当前状态：算法=${ORIG_ALGO:-?} 大小=${ORIG_SIZE:-0} swap=$WAS_SWAP"
echo "样本：${SAMPLE_MB} MB"
echo

# ---- 准备样本数据 ----
if [ -n "$DATA_FILE" ]; then
    [ -f "$DATA_FILE" ] || die "找不到 $DATA_FILE"
    SAMPLE="$DATA_FILE"
    echo "使用自定义数据：$DATA_FILE（$(du -h "$DATA_FILE" | cut -f1)）"
else
    SAMPLE="$WORK/sample.bin"
    if [ ! -f "$SAMPLE" ]; then
        echo "生成 ${SAMPLE_MB}MB 样本（混合可压缩 + 随机数据，更接近真实负载）..."
        # 一半来自 /dev/zero-ish 文本，一半来自 /dev/urandom：
        # 纯可压缩数据会夸大压缩率，纯随机数据又压缩不了，混合才接近日常使用
        HALF=$((SAMPLE_MB / 2))
        [ "$HALF" -lt 1 ] && HALF=1
        : > "$SAMPLE"
        i=0
        while [ "$i" -lt "$HALF" ]; do
            # 可压缩部分：重复文本
            yes "the quick brown fox jumps over the lazy dog 0123456789" 2>/dev/null | head -c 1048576 >> "$SAMPLE"
            i=$((i + 1))
        done
        i=0
        while [ "$i" -lt "$HALF" ]; do
            dd if=/dev/urandom bs=1M count=1 >> "$SAMPLE" 2>/dev/null
            i=$((i + 1))
        done
    fi
    echo "样本大小：$(du -h "$SAMPLE" | cut -f1)"
fi
echo

# ---- 逐算法测试 ----
#
# 注意：comp_algorithm 只列出 zram 自己 backends[] 里编进去的那几个。
# 模块注册的算法（lz4k / lz4kd / lz4k_oplus / lz4hc）不在那张表里，所以
#   永远不会出现在这个文件 -- 只读它会把本项目提供的算法全漏掉。
# 因此再扫一遍 /proc/crypto 里 type 为 compression 的 name，两者合并去重。
builtin=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr ' ' '\n' \
          | sed 's/^\[//; s/\]$//' | grep -v '^$')
regd=$(awk '/^name[[:space:]]*:/{n=$3} /^type[[:space:]]*:/{if ($3=="compression" && n!="") print n}' \
        /proc/crypto 2>/dev/null | sort -u)
ALGOS=$(printf '%s\n%s\n' "$builtin" "$regd" | grep -v '^$' | sort -u)
echo "可用算法：$(echo $ALGOS)"
echo

: > "$LOG"

for alg in $ALGOS; do
    printf '%-14s ' "$alg"

    [ "$WAS_SWAP" = "1" ] && swapoff /dev/block/zram0 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
    echo 0 > /sys/block/zram0/disksize 2>/dev/null

    if ! echo "$alg" > /sys/block/zram0/comp_algorithm 2>/dev/null; then
        echo "不支持（跳过）"
        continue
    fi

    SIZE=$(stat -c %s "$SAMPLE" 2>/dev/null || echo 0)
    echo "$SIZE" > /sys/block/zram0/disksize 2>/dev/null || { echo "设大小失败"; continue; }
    mkswap /dev/block/zram0 >/dev/null 2>&1

    START=$(date +%s%N 2>/dev/null || echo 0)
    dd if="$SAMPLE" of=/dev/block/zram0 bs=1M 2>/dev/null
    END=$(date +%s%N 2>/dev/null || echo 0)

    # mm_stat: orig_data_size compr_data_size mem_used_total mem_limit ...
    ORIG=$(awk '{print $1}' /sys/block/zram0/mm_stat 2>/dev/null)
    COMP=$(awk '{print $2}' /sys/block/zram0/mm_stat 2>/dev/null)
    MEM=$(awk '{print $3}' /sys/block/zram0/mm_stat 2>/dev/null)

    if [ -n "${COMP:-}" ] && [ "${COMP:-0}" -gt 0 ] 2>/dev/null; then
        RATIO=$(awk -v o="$ORIG" -v c="$COMP" 'BEGIN{printf "%.2f", o/c}')
        PCT=$(awk -v o="$ORIG" -v c="$COMP" 'BEGIN{printf "%.1f", c*100/o}')
        if [ "$START" -gt 0 ] && [ "$END" -gt "$START" ]; then
            MS=$(( (END - START) / 1000000 ))
        else
            MS="?"
        fi
        printf '压缩率 %sx  压缩到 %s%%  耗时 %sms  占用 %sKB\n' \
            "$RATIO" "$PCT" "$MS" "$((MEM / 1024))"
        printf '%s\t%s\t%s\t%s\t%s\n' "$alg" "$RATIO" "$PCT" "$MS" "$((MEM/1024))" >> "$LOG"
    else
        echo "无数据"
    fi
done

echo
echo "=== 汇总（按压缩率从高到低）==="
if [ -s "$LOG" ]; then
    sort -t"$(printf '\t')" -k2 -gr "$LOG" | awk -F'\t' '
        { printf "  %-14s %sx  %s%%  %sms  %sKB\n", $1, $2, $3, $4, $5 }
    '
    echo
    echo "压缩率越高 → 同样内存能压更多数据；耗时越低 → 换出/换入延迟越小。"
    echo "选择取决于你的瓶颈在哪：内存紧就选压缩率，卡顿敏感就选耗时。"
else
    echo "  （没有成功的测试结果）"
fi

# ---- 恢复 ----
echo
echo "=== 恢复原始配置 ==="
if [ -n "${ORIG_SIZE:-}" ] && [ "$ORIG_SIZE" != "0" ]; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null
    echo 0 > /sys/block/zram0/disksize 2>/dev/null
    [ -n "${ORIG_ALGO:-}" ] && echo "$ORIG_ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null
    echo "$ORIG_SIZE" > /sys/block/zram0/disksize 2>/dev/null
    mkswap /dev/block/zram0 >/dev/null 2>&1
    if [ "$WAS_SWAP" = "1" ]; then
        swapon /dev/block/zram0 2>/dev/null
    fi
    echo "已恢复 算法=$ORIG_ALGO 大小=$ORIG_SIZE swap=$WAS_SWAP"
else
    echo "原始 disksize 为 0，未恢复 swap"
fi
echo "详细结果：$LOG"