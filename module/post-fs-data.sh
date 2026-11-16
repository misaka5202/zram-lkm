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

# 文案目录。post-fs-data 阶段 property service 已起来，getprop 可用；
# 取不到时 i18n.sh 自己退回英文。
ZR_I18N="$MODDIR/i18n.sh"
[ -f "$ZR_I18N" ] && . "$ZR_I18N"
: "${M_MAINLINE_UNKNOWN:=unknown}"
: "${M_P_KMI_UNKNOWN:=[SKIP] cannot identify KMI, refusing to guess}"
: "${M_P_SKIP_LOADED:=[SKIP] %s (already loaded)}"
: "${M_P_AUTOSWITCH:=--- switching algorithm to %s ---}"
: "${M_P_UNKNOWN_ALGO:=[SKIP] zram0 does not know %s}"
: "${M_P_SWITCHED:=[OK]   switched to %s}"
: "${M_P_SWITCH_FAIL:=[FAIL] switching to %s failed}"

# 把 "模板 %s" 和值拼起来。<printf 在 Android 上是外部命令，实测每次 ~40 ms；
# 七行日志就是 300 ms，比省下来的半个 insmod 还贵，所以这里用纯参数展开。
_fmt() {
    case "$1" in
        *%s*) echo "${1%%%s*}$2${1#*%s}" ;;
        *)    echo "$1" ;;
    esac
}

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
echo "kmi: ${KMI:-$M_MAINLINE_UNKNOWN}" >> "$LOG"
if [ -z "$KMI" ]; then
    echo "$M_P_KMI_UNKNOWN" >> "$LOG"
fi

# ---- 内核已经有的算法，不必再装模块 ----
#
# 装模块有两项固定成本，都在 post-fs-data 这个阻塞阶段付：
#   * insmod 时间    七个模块实测合计约 170 ms
#   * 常驻内存       实测 coresize 合计约 150 KB，MemFree 少约 400 KB
#
# 有些内核把这些算法直接编进去了。那时模块装上也只会挂在那儿 —— 算法名已经
# 被占用，什么都不多出来，两份成本白付。842 更极端：厂商把内置那份注册成
# cra_priority=100，模块的 0 永远选不上（实测让设备用着 842 时，模块引用
# 计数仍然是 0）。
#
# 所以先在 /proc/crypto 里查名字，已经有了就不 insmod。zram_list 单独判断：
# 它只在确实有东西要显示时才值得加载。
#
# 这两个文件读起来都不便宜：实测每次读 /proc/crypto 要 70 ms、读一次
# comp_algorithm 要 63 ms，因为内核每次都要把全部算法枚举一遍。所以都只读
# 一次、缓存在变量里再匹配 —— 否则光是查七个算法就要 500 ms 以上，
# 比省下来的 insmod 还贵。
# 判据直接取「zram 现在能不能用这个算法」：comp_algorithm 里出现过的就说明
# 内核已经提供，再装模块纯属重复。
#
# 一开始我查的是 /proc/crypto（更"权威"），但那要多读一个文件：实测一次
# /proc/crypto 要 70 ms、comp_algorithm 63 ms，而且两个都得读就得 130 ms ——
# 在缺少算法的内核上这就是净亏。comp_algorithm 一个文件同时回答了"有没有"和
# "能不能用"，还能顺手写进日志。
#
# 读不到（比如 zram0 还没建）就当作全都没有，退化成老行为：全装。
ZR_COMP_FILE="${ZR_COMP_FILE:-/sys/block/zram0/comp_algorithm}"

_ZR_COMP_RAW=""
_ZR_COMP_SET=""
_ZR_COMP_LOADED=0

_comp_load() {
    [ "$_ZR_COMP_LOADED" = 1 ] && return 0
    _ZR_COMP_RAW=$(cat "$ZR_COMP_FILE" 2>/dev/null)
    # 当前选中的那个是 [zstd] 这种带方括号的写法，比对前一并去掉
    _ZR_COMP_SET=" $(echo "$_ZR_COMP_RAW" | tr ' []' '   ') "
    _ZR_COMP_LOADED=1
}

comp_listed() {
    _comp_load
    case "$_ZR_COMP_SET" in *" $1 "*) return 0 ;; esac
    return 1
}

module_algos() {
    case "$1" in
        zstdn)     echo "zstdn zstdn_o" ;;
        zram_list) echo "" ;;
        *)         echo "$1" ;;
    esac
}

# 0 = 该加载（还有算法是内核没有的）；1 = 不用加载
module_needed() {
    local a
    for a in $(module_algos "$1"); do
        comp_listed "$a" || return 0
    done
    return 1
}

# 列表要不要美化：只有装了算法模块才需要 —— 那些算法名不在 zram 的
# backends[] 里，不 hook 就看不见。什么都没装就没必要动 zram0。
need_list() {
    [ "$LOADED_ANY" = "1" ]
}

_MODULES=$(cat /proc/modules 2>/dev/null)

mod_loaded() {
    case "$_MODULES" in *"$1 "*) return 0 ;; esac
    return 1
}

LOADED_ANY=0
LIST_KO=""
LIST_NAME=""

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
    if mod_loaded "$modname"; then
        _fmt "$M_P_SKIP_LOADED" "$name" >> "$LOG"
        continue
    fi

    # zram_list 必须留到最后：它要不要装，取决于前面到底装成了几个。
    # 按文件名排序它排在 zstdn 前面（'r' < 's'），就地判断会漏掉后者。
    if [ "$modname" = "zram_list" ]; then
        LIST_KO="$ko"; LIST_NAME="$name"
        continue
    fi

    if ! module_needed "$modname"; then
        _fmt "$M_P_SKIP_BUILTIN" "$name" >> "$LOG"
        continue
    fi

    if out=$(insmod "$ko" 2>&1); then
        echo "[OK]   $name" >> "$LOG"
        LOADED_ANY=1
    else
        echo "[FAIL] $name: $out" >> "$LOG"
    fi
done

# ---- zram_list 最后决定 ----
if [ -n "$LIST_KO" ]; then
    if mod_loaded zram_list; then
        _fmt "$M_P_SKIP_LOADED" "$LIST_NAME" >> "$LOG"
    elif need_list; then
        if out=$(insmod "$LIST_KO" 2>&1); then
            echo "[OK]   $LIST_NAME" >> "$LOG"
        else
            echo "[FAIL] $LIST_NAME: $out" >> "$LOG"
        fi
    else
        _fmt "$M_P_SKIP_LIST" "$LIST_NAME" >> "$LOG"
    fi
fi

echo "--- loaded ---" >> "$LOG"
# 模式里必须把 842 和 lz4hc 写全：'lz4k' 匹配不到 'lz4hc'，漏掉会让日志
# 看起来像"模块没加载"，实际是 grep 写窄了。
lsmod 2>/dev/null | grep -E '^(842|lz4hc|lz4k|lz4kd|lz4k_oplus|zstdn|zstdp|zram_list) ' >> "$LOG"

echo "--- zram0 comp_algorithm ---" >> "$LOG"
_comp_load; echo "$_ZR_COMP_RAW" >> "$LOG"

# ---- 可选：自动切换算法 ----
ALGO=""
AUTO_SWITCH="0"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

if [ "$AUTO_SWITCH" = "1" ] && [ -n "$ALGO" ]; then
    _fmt "$M_P_AUTOSWITCH" "$ALGO" >> "$LOG"
    if ! comp_listed "$ALGO"; then
        _fmt "$M_P_UNKNOWN_ALGO" "$ALGO" >> "$LOG"
    else
        # 记录当前 swap 状态和大小，切完恢复
        SWAPSIZE=$(cat /sys/block/zram0/disksize 2>/dev/null)
        WAS_SWAP=0
        grep -q '^/dev/block/zram0' /proc/swaps 2>/dev/null && WAS_SWAP=1

        [ "$WAS_SWAP" = "1" ] && swapoff /dev/block/zram0 2>/dev/null
        if echo "$ALGO" > /sys/block/zram0/comp_algorithm 2>>"$LOG"; then
            _fmt "$M_P_SWITCHED" "$ALGO" >> "$LOG"
            [ -n "$SWAPSIZE" ] && echo "$SWAPSIZE" > /sys/block/zram0/disksize 2>/dev/null
            [ "$WAS_SWAP" = "1" ] && { mkswap /dev/block/zram0 >/dev/null 2>&1; swapon /dev/block/zram0 2>/dev/null; }
        else
            _fmt "$M_P_SWITCH_FAIL" "$ALGO" >> "$LOG"
        fi
    fi
fi

echo "=== done ===" >> "$LOG"