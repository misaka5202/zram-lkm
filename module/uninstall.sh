#!/system/bin/sh
# uninstall.sh - 卸载时清理
#
# 不 rmmod：已注册的 crypto 算法可能正被 zram 或别的使用者持有，
# 强拆就是 use-after-free。重启后自然不再加载。
#
# 但「删了 .ko」不等于「算法立刻消失」：已经注册进 crypto 的实现会一直留到
# 下次重启。不说清楚的话，用户会以为卸载没生效。

MODDIR=${0%/*}
ZR_I18N="$MODDIR/i18n.sh"
[ -f "$ZR_I18N" ] || ZR_I18N=/data/adb/modules/zram_lkm/i18n.sh
[ -f "$ZR_I18N" ] && . "$ZR_I18N"

: "${M_U_NOTE:=Module removed. Rebooting is cleaner: the algorithms stay registered}"
: "${M_U_NOTE2:=until the next reboot even after the .ko files are gone.}"
: "${M_U_NO_REBOOT:=(no reboot performed)}"

rm -f "$MODDIR/zram_lkm.log" "$MODDIR/zram_lkm.log.old"
# 旧版本的日志在 /data/local/tmp（symlink 攻击面，已废弃）；卸载时一并清理
rm -f /data/local/tmp/zram_lkm.log

echo "$M_U_NOTE"
echo "$M_U_NOTE2"
echo "$M_U_NO_REBOOT"