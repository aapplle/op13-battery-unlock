#!/system/bin/sh
# ============================================================
# uv2800 - lib/route.sh
# 按 standard/late-load 路线与 mount namespace 跑 service.sh。
# 依赖 lib/common.sh 的 _uv_route_log/_uv_ns_diff。
# ============================================================

# ---------- 跑 service.sh（路线 + 命名空间） ----------
_uv_run_service() {
    _uvrs_late=0
    [ "$(_uv_route_log)" = "late-load" ] && _uvrs_late=1
    _uvrs_ns=0
    _uv_ns_diff && _uvrs_ns=1
    if [ "$_uvrs_ns" = 1 ] && command -v nsenter >/dev/null 2>&1 && nsenter -t 1 -m -- true 2>/dev/null; then
        if [ "$_uvrs_late" = 1 ]; then
            KSU_LATE_LOAD=1 nsenter -t 1 -m -- sh "$MODDIR/service.sh" >> "$LAST" 2>&1
        else
            nsenter -t 1 -m -- sh "$MODDIR/service.sh" >> "$LAST" 2>&1
        fi
        return $?
    fi
    if [ "$_uvrs_late" = 1 ]; then
        KSU_LATE_LOAD=1 sh "$MODDIR/service.sh" >> "$LAST" 2>&1
    else
        sh "$MODDIR/service.sh" >> "$LAST" 2>&1
    fi
}

