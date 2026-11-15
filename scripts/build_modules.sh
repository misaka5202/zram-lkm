#!/usr/bin/env bash
# 为单个 KMI 编译全部 zram 压缩算法模块。
#
# 用法: build_modules.sh <kmi> <kdir> <workspace> <outdir>
#
#   kmi        形如 android14-6.1
#   kdir       DDK 镜像里该 KMI 的内核树（含 Module.symvers / 头文件）
#   workspace  仓库根目录
#   outdir     产物目录，输出 <module>-<kmi>.ko
#
# 每项失败只记 warning，不中断整体 —— 某个算法在某个 KMI 上不适配时，
# 其余算法仍然出货。
set -uo pipefail

KMI="${1:?kmi}"
KDIR="${2:?kdir}"
WS="${3:?workspace}"
OUT="${4:?outdir}"
shift 4
# 额外 make 参数（本地树需要 O=out + 工具链；DDK 镜像里不需要）
EXTRA_MAKE_ARGS=("$@")

mkdir -p "$OUT"
NPROC="$(nproc 2>/dev/null || echo 4)"

FAILED=()

log()  { printf '%s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; FAILED+=("$*"); }

clean_src() {
    local src="$1"
    find "$src" -name '*.o' -delete 2>/dev/null || true
    find "$src" -name '.*.cmd' -delete 2>/dev/null || true
    find "$src" -name '*.ko' -delete 2>/dev/null || true
    find "$src" -name '*.mod' -delete 2>/dev/null || true
    find "$src" -name '*.mod.c' -delete 2>/dev/null || true
    rm -f "$src/modules.order" "$src/Module.symvers" 2>/dev/null || true
}

# ---------------------------------------------------------------- 算法模块 ---
# 目录名 == 模块名，Makefile 里 obj-m 已按此命名
for m in lz4k lz4kd lz4k_oplus lz4hc 842 zstdn zram_list; do
    SRC="$WS/extra/$m"
    [ -f "$SRC/Makefile" ] || { warn "$m @ $KMI (无 Makefile)"; continue; }
    log "=== $m @ $KMI ==="
    clean_src "$SRC"
    if make -C "$KDIR" M="$SRC" "${EXTRA_MAKE_ARGS[@]}" modules -j"$NPROC"; then
        if [ -f "$SRC/$m.ko" ]; then
            cp "$SRC/$m.ko" "$OUT/$m-$KMI.ko"
            log "  [OK] $m-$KMI.ko"
        else
            warn "$m @ $KMI (无产物)"
        fi
    else
        warn "$m @ $KMI"
    fi
    clean_src "$SRC"
done

log ""
log "=== $KMI 产物 ==="
ls -lh "$OUT" 2>/dev/null || true
log ""

if [ ${#FAILED[@]} -gt 0 ]; then
    log "=== $KMI 失败项 (${#FAILED[@]}) ==="
    printf '  - %s\n' "${FAILED[@]}"
fi

# 全部失败才让 job 失败，部分成功仍出货
if [ ${#FAILED[@]} -gt 0 ] && [ "$(ls -1 "$OUT"/*.ko 2>/dev/null | wc -l)" -eq 0 ]; then
    log "本 KMI 没有任何产物，判为失败"
    exit 1
fi

exit 0