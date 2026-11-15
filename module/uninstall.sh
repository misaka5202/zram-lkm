#!/system/bin/sh
# uninstall.sh - 卸载时清理
#
# 不 rmmod：已注册的 crypto 算法可能正被 zram 或别的使用者持有，
# 强拆就是 use-after-free。重启后自然不再加载。

rm -f /data/local/tmp/zram_lkm.log
rm -f /data/local/tmp/zram_lkm.log.old
