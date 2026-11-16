# customize.sh - 安装脚本（KernelSU 在解压 zip 后执行本文件）
#
# 模块不含 system/ 覆盖：.ko 就放在模块自己的 ko/ 目录里，由启动脚本直接
# insmod。KernelSU 的 system/ 需要额外装 metamodule（如 meta-overlayfs）才会
# 挂载，把 .ko 放那里等于给用户加了一个隐形前提。
#
# 也不调用 set_perm/set_perm_recursive —— 那是 Magisk 安装器时代的辅助函数，
# 直接 chmod 在各家管理器下行为一致。
#
# 文案走 i18n.sh，语言按系统属性判定，默认英文。

SKIPUNZIP=0

# 文案目录与本脚本同目录；取不到就退回英文硬编码（下面的兜底值）。
ZR_I18N="${0%/*}/i18n.sh"
[ -f "$ZR_I18N" ] || ZR_I18N="/data/adb/modules/zram_lkm/i18n.sh"
if [ -f "$ZR_I18N" ]; then
    . "$ZR_I18N"
else
    M_TITLE="ZRAM LKM"
    M_TAGLINE="ZRAM compression algorithm extension"
    M_ARCH_UNSUPPORTED="This module is arm64-only. Current architecture: "
    M_INSTALL_ABORTED="Installation aborted"
    M_KERNEL="Kernel  : "
    M_MAINLINE_UNSUPPORTED="Mainline not in the supported list: "
    M_MAINLINE_UNKNOWN="unknown"
    M_ALGOS="Algorithms: lz4k / lz4kd / lz4k_oplus / lz4hc / 842"
    M_EXTRA="Extra     : zram_list (makes the module algorithms show in comp_algorithm)"
    M_LOAD_ONLY="Loads the modules only, does not switch algorithms"
    M_SWITCH_RISK="  switching rebuilds the zram contents; doing that at boot risks data loss"
    M_MANUAL_SWITCH="Manual switch:"
    M_LOG_PATH="Log: /data/local/tmp/zram_lkm.log"
    M_REBOOT_HINT="Reboot after installation"
fi

ui_print " "
ui_print "*********************************"
ui_print "  $M_TITLE"
ui_print "  $M_TAGLINE"
ui_print "*********************************"
ui_print " "

case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
        ui_print "! ${M_ARCH_UNSUPPORTED}$(uname -m)"
        abort "  $M_INSTALL_ABORTED"
        ;;
esac

KREL=$(uname -r)
ui_print "- ${M_KERNEL}$KREL"

major=$(echo "$KREL" | grep -oE '^[0-9]+[.][0-9]+')
case "$major" in
    5.10) ui_print "- $M_MAINLINE_510" ;;
    5.15) ui_print "- $M_MAINLINE_515" ;;
    6.1)  ui_print "- $M_MAINLINE_61" ;;
    6.6)  ui_print "- $M_MAINLINE_66" ;;
    6.12) ui_print "- $M_MAINLINE_612" ;;
    6.18) ui_print "- $M_MAINLINE_618" ;;
    *)    ui_print "! ${M_MAINLINE_UNSUPPORTED}${major:-$M_MAINLINE_UNKNOWN}" ;;
esac

ui_print "- $M_ALGOS"
ui_print "- $M_EXTRA"
ui_print " "
ui_print "- $M_LOAD_ONLY"
ui_print "$M_SWITCH_RISK"
ui_print "- $M_MANUAL_SWITCH"
ui_print "    echo lz4k_oplus > /sys/block/zram0/comp_algorithm"
ui_print "- $M_LOG_PATH"
ui_print " "
ui_print "$M_REBOOT_HINT"
ui_print " "