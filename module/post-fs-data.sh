#!/system/bin/sh
# post-fs-data.sh - 开机早期加载压缩算法模块
#
# 为什么用 post-fs-data 而不是 service.sh：
#   KernelSU 文档把 post-fs-data 标为"阻塞、能不用就不用"，但这里的加载
#   必须赶在 Android 配置 zram0 之前完成 —— 算法要在 zram 决定用哪个
#   compressor 的时候就已经注册好。放到 late_start 就晚了。
#   脚本只做 insmod，耗时在毫秒级，不接近 10 秒上限。
#
# 模块路径用规范写法：MODDIR=${0%/*}，不硬编码 /data/adb/modules/zram_lkm。
#
# **加载模块** 与 **启用算法** 是两件事，这里只做前者。
#   切换 /sys/block/zram0/comp_algorithm 会重置该 zram 设备（现有内容丢失），
#   而 Android 通常把 zram0 当 swap 用。开机阶段自动切换会清掉 swap 里的页，
#   内存紧张时有实际风险。所以默认只加载，由用户自己决定何时切换。
#
#   想开机自动切换，在模块目录放 zram_lkm.conf：
#       ALGO=lz4k_oplus
#       AUTO_SWITCH=1

MODDIR=${0%/*}
LOG="/data/local/tmp/zram_lkm.log"
CONF="$MODDIR/zram_lkm.conf"

: > "$LOG"
echo "=== zram_lkm $(date) ===" >> "$LOG"
echo "kernel: $(uname -r)" >> "$LOG"

# ---- 按 KMI 选 .ko ----
#
# 合并包里 ko/ 下有全部 KMI 的 .ko（5 个算法 x 7 个 KMI = 35 个）。
# 不筛选的话会去加载别的内核版本编的模块，虽然只是 insmod 失败，但日志会被
# 一堆 "unknown symbol" 淹没，真正的问题反而看不见。
#
# KMI 推导与 service.sh 一致：内核主版本优先，只有 5.10/5.15 这种跨两代的
# 才看系统属性。
detect_kmi() {
    local krel major android pick rel
    krel=$(uname -r)
    major=$(echo "$krel" | grep -oE '^[0-9]+[.][0-9]+')
    android=$(echo "$krel" | grep -oE 'android[0-9]+' | head -1)

    if [ -z "$android" ]; then
        case "$major" in
            5.10) android="android12 android13" ;;
            5.15) android="android13 android14" ;;
            6.1)  android="android14" ;;
            6.6)  android="android15" ;;
            6.12) android="android16" ;;
            6.18) android="android17" ;;
            *)    android="" ;;
        esac
        if [ "$(echo $android | wc -w)" -gt 1 ]; then
            rel=$(getprop ro.build.version.release 2>/dev/null | grep -oE '^[0-9]+')
            [ -z "$rel" ] && rel=$(getprop ro.build.version.sdk 2>/dev/null)
            case "$rel" in
                31|32|12) pick=android12 ;; 33|13) pick=android13 ;;
                34|14) pick=android14 ;; 35|15) pick=android15 ;;
                36|16) pick=android16 ;; 37|17) pick=android17 ;;
                *) pick="" ;;
            esac
            for c in $android; do [ "$c" = "$pick" ] && { android="$pick"; break; }; done
        fi
        android=$(echo "$android" | cut -d" " -f1)
    fi
    [ -n "$android" ] && [ -n "$major" ] && echo "$android-$major"
}

KMI=$(detect_kmi)
echo "kmi: ${KMI:-未识别}" >> "$LOG"
if [ -z "$KMI" ]; then
    echo "[SKIP] 无法识别 KMI，拒绝猜测（会加载错内核版本编的模块）" >> "$LOG"
fi

for ko in "$MODDIR"/ko/*.ko; do
    [ -f "$ko" ] || continue
    name=$(basename "$ko")
    # 有 KMI 信息时只加载匹配的那一组
    case "$name" in
        *-"$KMI".ko) ;;
        *)
            [ -n "$KMI" ] && continue
            ;;
    esac
    # 已加载就跳过，别记成失败 —— 重跑脚本或手动调用时这很常见
    modname=${name%-android*}
    if grep -q "^${modname} " /proc/modules 2>/dev/null; then
        echo "[SKIP] $name (已加载)" >> "$LOG"
        continue
    fi

    if out=$(insmod "$ko" 2>&1); then
        echo "[OK]   $name" >> "$LOG"
    else
        echo "[FAIL] $name: $out" >> "$LOG"
    fi
done

echo "--- loaded ---" >> "$LOG"
lsmod 2>/dev/null | grep -E 'lz4k|lz4kd|zstdn|zstdp' >> "$LOG"

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