#!/system/bin/sh
# KernelSU / APatch 模块安装脚本。
#
# 只负责把匹配当前 KMI 的 .ko 拷进模块目录，不在这里加载 —— 加载放在
# post-fs-data.sh，因为那时 /proc/kallsyms、crypto 框架都已就绪。
SKIPUNZIP=0

ui_print " "
ui_print "*** ZRAM LKM ***"
ui_print " "

MODDIR="${MODPATH:-${0%/*}}"
KMI_RAW="$(uname -r)"
ui_print "- 内核: $KMI_RAW"

# 从 uname -r 推断 KMI
#   5.10.x-android12-*  -> android12-5.10
#   5.10.x-android13-*  -> android13-5.10
#   5.15.x-android13-*  -> android13-5.15
#   5.15.x-android14-*  -> android14-5.15
#   6.1.x-android14-*   -> android14-6.1
#   6.6.x-android15-*   -> android15-6.6
#   6.12.x-android16-*  -> android16-6.12
case "$KMI_RAW" in
    *android12-5.10*) KMI="android12-5.10" ;;
    *android13-5.10*) KMI="android13-5.10" ;;
    *android13-5.15*) KMI="android13-5.15" ;;
    *android14-5.15*) KMI="android14-5.15" ;;
    *android14-6.1*)  KMI="android14-6.1" ;;
    *android15-6.6*)  KMI="android15-6.6" ;;
    *android16-6.*)   KMI="android16-6.12" ;;
    *) KMI="" ;;
esac

if [ -z "$KMI" ]; then
    ui_print "! 无法从内核版本识别 KMI：$KMI_RAW"
    ui_print "! 包里如果只有一组 .ko，将直接使用；否则需要手动选择。"
else
    ui_print "- KMI: $KMI"
fi

# 兼容两种包结构：
#   单 KMI 包  -> ko/<name>-<kmi>.ko
#   全 KMI 包  -> ko/<name>-<kmi>.ko（多组，按 KMI 挑）
if [ -n "$KMI" ] && ls "$MODDIR/ko/"*-"$KMI".ko >/dev/null 2>&1; then
    mkdir -p "$MODDIR/system/lib/modules"
    for f in "$MODDIR/ko/"*-"$KMI".ko; do
        cp -f "$f" "$MODDIR/system/lib/modules/"
        ui_print "  + $(basename "$f")"
    done
elif ls "$MODDIR/ko/"*.ko >/dev/null 2>&1; then
    mkdir -p "$MODDIR/system/lib/modules"
    cp -f "$MODDIR/ko/"*.ko "$MODDIR/system/lib/modules/"
    ui_print "  + 使用包内唯一的 ko 组"
else
    ui_print "! 包里没有找到 .ko"
fi

# 清掉原始 ko 目录，模块只需要 system/lib/modules 下那份
rm -rf "$MODDIR/ko"

set_perm_recursive "$MODDIR" 0 0 0755 0644
set_perm_recursive "$MODDIR/system/lib/modules" 0 0 0755 0644
set_perm "$MODDIR/post-fs-data.sh" 0 0 0755
set_perm "$MODDIR/service.sh" 0 0 0755
set_perm "$MODDIR/uninstall.sh" 0 0 0755

ui_print " "
ui_print "- 重启后自动加载"
ui_print "- 切换算法（会重建 zram 内容）："
ui_print "    echo lz4k_oplus > /sys/block/zram0/comp_algorithm"
ui_print "- 加载日志: /data/local/tmp/zram_lkm.log"
ui_print " "