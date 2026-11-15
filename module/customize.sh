# customize.sh - 安装脚本（KernelSU 在解压 zip 后执行本文件）
#
# 模块不含 system/ 覆盖：.ko 就放在模块自己的 ko/ 目录里，由启动脚本直接
# insmod。KernelSU 的 system/ 需要额外装 metamodule（如 meta-overlayfs）才会
# 挂载，把 .ko 放那里等于给用户加了一个隐形前提。
#
# 也不调用 set_perm/set_perm_recursive —— 那是 Magisk 安装器时代的辅助函数，
# 直接 chmod 在各家管理器下行为一致。

SKIPUNZIP=0

ui_print " "
ui_print "*********************************"
ui_print "  ZRAM LKM"
ui_print "  ZRAM 压缩算法扩展"
ui_print "*********************************"
ui_print " "

case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
        ui_print "! 本模块只支持 arm64，当前架构：$(uname -m)"
        abort "  安装已中止"
        ;;
esac

KREL=$(uname -r)
ui_print "- 内核版本: $KREL"

major=$(echo "$KREL" | grep -oE '^[0-9]+[.][0-9]+')
case "$major" in
    5.10) ui_print "- 内核主线: 5.10（Android 12 / 13）" ;;
    5.15) ui_print "- 内核主线: 5.15（Android 13 / 14）" ;;
    6.1)  ui_print "- 内核主线: 6.1（Android 14）" ;;
    6.6)  ui_print "- 内核主线: 6.6（Android 15）" ;;
    6.12) ui_print "- 内核主线: 6.12（Android 16）" ;;
    *)    ui_print "! 未在支持列表中的内核主线：${major:-未知}" ;;
esac

ui_print "- 算法: lz4k / lz4kd / lz4k_oplus / lz4hc / 842"
ui_print "- 附加: zram_list（让模块算法出现在 comp_algorithm）"
ui_print " "
ui_print "- 只加载模块，不自动切换算法"
ui_print "  切换会重建 zram 内容，开机阶段做这件事有掉数据风险"
ui_print "- 手动切换:"
ui_print "    echo lz4k_oplus > /sys/block/zram0/comp_algorithm"
ui_print "- 日志: /data/local/tmp/zram_lkm.log"
ui_print " "
ui_print "安装完成后请重启设备"
ui_print " "
