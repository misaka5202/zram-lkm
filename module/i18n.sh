#!/system/bin/sh
# i18n.sh - 模块文案的语言目录
#
# 由 customize.sh / action.sh / service.sh / post-fs-data.sh / uninstall.sh source。
#
# 设计约束（重要）：**机器可读的部分一律不翻译**。
#   [OK] / [FAIL] / [SKIP] / [--]         标记
#   算法名、KMI 标签、内核版本串、路径     数据
# 只翻译这些标记后面的人读描述。这样用户贴出来的日志
# 既能被人读懂，也能被 grep 正确解析。
#
# 语言判定顺序：
#   persist.sys.locale  →  ro.product.locale  →  ro.product.locale.language
# 取不到就用英文（国际用户优先，而不是默认中文）。
#
# 只在 [5.10, 6.19) 的内核上会被用到；其他情况调用方自己决定是否 source。

_i18n_locale() {
    for _p in persist.sys.locale ro.product.locale ro.product.locale.language; do
        _v=$(getprop "$_p" 2>/dev/null)
        [ -n "$_v" ] && { echo "$_v"; return; }
    done
    echo en
}

# 允许 installer / 用户强制指定：ZRAM_LKM_LANG=zh
if [ -n "$ZRAM_LKM_LANG" ]; then
    _RAW=$ZRAM_LKM_LANG
else
    _RAW=$(_i18n_locale)
fi

# 只看语言部分，忽略地区：zh-CN / zh_CN / zh-Hans-CN / zh-rTW 都归到 zh
case "$_RAW" in
    zh*|*Hans*|*Hant*|*CN*|*TW*|*HK*) LANG_CODE=zh ;;
    ja*|*JP*)                         LANG_CODE=ja ;;
    *)                                LANG_CODE=en ;;
esac

# ---------------------------------------------------------------------------
# 文案
#
# 变量名统一 M_ 前缀。英文是兜底，任何键在目标语言里缺失都回退英文。
# ---------------------------------------------------------------------------
M_TITLE="ZRAM LKM"
M_TAGLINE="ZRAM compression algorithm extension"

# --- customize.sh ---
M_ARCH_UNSUPPORTED="This module is arm64-only. Current architecture: "
M_INSTALL_ABORTED="Installation aborted"
M_KERNEL="Kernel  : "
M_MODULE_VER="Version : "
M_MAINLINE_510="Mainline: 5.10 (Android 12 / 13)"
M_MAINLINE_515="Mainline: 5.15 (Android 13 / 14)"
M_MAINLINE_61="Mainline: 6.1 (Android 14)"
M_MAINLINE_66="Mainline: 6.6 (Android 15)"
M_MAINLINE_612="Mainline: 6.12 (Android 16)"
M_MAINLINE_618="Mainline: 6.18 (Android 17)"
M_MAINLINE_UNSUPPORTED="Mainline not in the supported list: "
M_MAINLINE_UNKNOWN="unknown"
M_ALGOS="Algorithms: lz4k / lz4kd / lz4k_oplus / lz4hc / 842"
M_EXTRA="Extra     : zram_list (makes the module algorithms show in comp_algorithm)"
M_LOAD_ONLY="Loads the modules only, does not switch algorithms"
M_SWITCH_RISK="  switching rebuilds the zram contents; doing that at boot risks data loss"
M_MANUAL_SWITCH="Manual switch:"
M_LOG_PATH="Log: /data/local/tmp/zram_lkm.log"
M_REBOOT_HINT="Reboot after installation"

# --- action.sh ---
M_A_LOADED="=== Loaded algorithm modules ==="
M_A_NONE="none loaded"
M_A_CRYPTO="=== compression algorithms registered in crypto ==="
M_A_COMP="=== zram0 comp_algorithm ==="
M_A_NO_ZRAM0="  (no zram0)"
M_A_HINTS="=== Notes ==="
M_A_HINT_SWITCH="  switching the algorithm rebuilds the zram contents (on Android zram0"
M_A_HINT_SWITCH2="  is usually swap):"
M_A_HINT_ZRAMLIST="  zram_list only prettifies the list display; it does not affect usability."
M_A_LOG="=== Log (last 20 lines) ==="
M_A_NO_LOG="(no log)"

# --- post-fs-data.sh (log only) ---
M_P_KMI_UNKNOWN="[SKIP] cannot identify KMI, refusing to guess (would load modules built for another kernel version)"
M_P_SKIP_LOADED="[SKIP] %s (already loaded)"
M_P_AUTOSWITCH="--- switching algorithm to %s ---"
M_P_UNKNOWN_ALGO="[SKIP] zram0 does not know %s (the module probably did not load)"
M_P_SWITCHED="[OK]   switched to %s"
M_P_SWITCH_FAIL="[FAIL] switching to %s failed"

# --- service.sh / uninstall.sh ---
M_S_LOADED="[OK]   zram modules handled"
M_U_NOTE="Module removed. Rebooting is cleaner: the algorithms stay registered"
M_U_NOTE2="until the next reboot even after the .ko files are gone."
M_U_NO_REBOOT="(no reboot performed)"

# ---------------------------------------------------------------------------
# 语言覆盖
# ---------------------------------------------------------------------------
case "$LANG_CODE" in
zh)
    M_TAGLINE="ZRAM 压缩算法扩展"

    M_ARCH_UNSUPPORTED="本模块只支持 arm64，当前架构："
    M_INSTALL_ABORTED="安装已中止"
    M_KERNEL="内核版本: "
    M_MODULE_VER="模块版本: "
    M_MAINLINE_510="内核主线: 5.10（Android 12 / 13）"
    M_MAINLINE_515="内核主线: 5.15（Android 13 / 14）"
    M_MAINLINE_61="内核主线: 6.1（Android 14）"
    M_MAINLINE_66="内核主线: 6.6（Android 15）"
    M_MAINLINE_612="内核主线: 6.12（Android 16）"
    M_MAINLINE_618="内核主线: 6.18（Android 17）"
    M_MAINLINE_UNSUPPORTED="未在支持列表中的内核主线："
    M_MAINLINE_UNKNOWN="未知"
    M_ALGOS="算法: lz4k / lz4kd / lz4k_oplus / lz4hc / 842"
    M_EXTRA="附加: zram_list（让模块算法出现在 comp_algorithm）"
    M_LOAD_ONLY="只加载模块，不自动切换算法"
    M_SWITCH_RISK="  切换会重建 zram 内容，开机阶段做这件事有掉数据风险"
    M_MANUAL_SWITCH="手动切换:"
    M_LOG_PATH="日志: /data/local/tmp/zram_lkm.log"
    M_REBOOT_HINT="安装完成后请重启设备"

    M_A_LOADED="=== 已加载的算法模块 ==="
    M_A_NONE="未加载"
    M_A_CRYPTO="=== crypto 已注册的 compression 算法 ==="
    M_A_COMP="=== zram0 的 comp_algorithm ==="
    M_A_NO_ZRAM0="  (没有 zram0)"
    M_A_HINTS="=== 提示 ==="
    M_A_HINT_SWITCH="  切换算法会重建 zram 内容（Android 上 zram0 通常是 swap）："
    M_A_HINT_SWITCH2=""
    M_A_HINT_ZRAMLIST="  zram_list 只美化列表显示，不影响实际可用性。"
    M_A_LOG="=== 日志（末尾 20 行）==="
    M_A_NO_LOG="(无日志)"

    M_P_KMI_UNKNOWN="[SKIP] 无法识别 KMI，拒绝猜测（会加载错内核版本编的模块）"
    M_P_SKIP_LOADED="[SKIP] %s (已加载)"
    M_P_AUTOSWITCH="--- 自动切换算法到 %s ---"
    M_P_UNKNOWN_ALGO="[SKIP] zram0 不认识 %s（模块可能没加载成功）"
    M_P_SWITCHED="[OK]   已切到 %s"
    M_P_SWITCH_FAIL="[FAIL] 切换 %s 失败"

    M_S_LOADED="[OK]   zram 模块已处理"
    M_U_NOTE="模块已移除。建议重启：.ko 文件删掉后算法仍会保持注册，"
    M_U_NOTE2="直到下次重启。"
    M_U_NO_REBOOT="(未执行重启)"
    ;;
ja)
    M_TAGLINE="ZRAM 圧縮アルゴリズム拡張"

    M_ARCH_UNSUPPORTED="このモジュールは arm64 専用です。現在のアーキテクチャ: "
    M_INSTALL_ABORTED="インストールを中止しました"
    M_KERNEL="カーネル: "
    M_MODULE_VER="バージョン: "
    M_MAINLINE_UNSUPPORTED="サポート対象外のメインライン: "
    M_MAINLINE_UNKNOWN="不明"
    M_ALGOS="アルゴリズム: lz4k / lz4kd / lz4k_oplus / lz4hc / 842"
    M_LOAD_ONLY="モジュールを読み込むだけで、アルゴリズムは切り替えません"
    M_MANUAL_SWITCH="手動切り替え:"
    M_LOG_PATH="ログ: /data/local/tmp/zram_lkm.log"
    M_REBOOT_HINT="インストール後に再起動してください"

    M_A_LOADED="=== 読み込み済みのアルゴリズムモジュール ==="
    M_A_NONE="未読み込み"
    M_A_CRYPTO="=== crypto に登録された compression アルゴリズム ==="
    M_A_COMP="=== zram0 の comp_algorithm ==="
    M_A_NO_ZRAM0="  (zram0 がありません)"
    M_A_HINTS="=== 補足 ==="
    M_A_LOG="=== ログ（末尾 20 行）==="
    M_A_NO_LOG="(ログなし)"

    M_P_KMI_UNKNOWN="[SKIP] KMI を判別できません。推測はしません（別カーネル向けのモジュールを読み込むため）"
    M_P_SKIP_LOADED="[SKIP] %s (読み込み済み)"
    M_P_AUTOSWITCH="--- アルゴリズムを %s に切り替え ---"
    M_P_UNKNOWN_ALGO="[SKIP] zram0 は %s を知りません（モジュールの読み込みに失敗した可能性）"
    M_P_SWITCHED="[OK]   %s に切り替えました"
    M_P_SWITCH_FAIL="[FAIL] %s への切り替えに失敗"
    ;;
esac