#!/system/bin/sh
# 卸载时先 rmmod，避免模块一直占着 crypto 算法名。
MODDIR=${0%/*}
for ko in "$MODDIR"/system/lib/modules/*.ko; do
    [ -f "$ko" ] || continue
    modname=$(basename "$ko" .ko)
    rmmod "$modname" 2>/dev/null
done
rm -f /data/local/tmp/zram_lkm.log
