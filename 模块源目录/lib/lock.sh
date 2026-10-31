#!/system/bin/sh
# ============================================================
# uv2800 - lib/lock.sh
# WebUI 写锁 / 等待现有脚本 / 模块状态前置检查。
# 依赖 lib/common.sh 的 _uv_loaded 等。
# ============================================================

# ---------- 锁 ----------
_uv_unlock() {
    if [ -f "$LOCK/pid" ]; then
        _uvu_pid=$(cat "$LOCK/pid" 2>/dev/null)
        if [ "$_uvu_pid" = "$$" ]; then
            rm -rf "$LOCK" 2>/dev/null
        fi
    fi
}

_uv_lock() {
    mkdir -p "$BK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
        printf 'webui.sh\n' > "$LOCK/cmd" 2>/dev/null
        trap '_uv_unlock' 0
        trap 'exit 130' 1 2 15
        return 0
    fi
    _uvl_pid=$(cat "$LOCK/pid" 2>/dev/null)
    _uvl_stale=1
    case "$_uvl_pid" in
        ''|*[!0-9]*) : ;;
        *)
            if kill -0 "$_uvl_pid" 2>/dev/null; then
                _uvl_cmd=$(cat "/proc/$_uvl_pid/cmdline" 2>/dev/null | tr '\0' ' ')
                case "$_uvl_cmd" in
                    *webui.sh*) _uvl_stale=0 ;;
                esac
            fi
            ;;
    esac
    if [ "$_uvl_stale" = 1 ]; then
        rm -rf "$LOCK" 2>/dev/null
        if mkdir "$LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
            printf 'webui.sh\n' > "$LOCK/cmd" 2>/dev/null
            trap '_uv_unlock' 0
            trap 'exit 130' 1 2 15
            return 0
        fi
    fi
    printf 'RESULT=busy\nCODE=busy\n'
    exit 3
}

_uv_lock_state() {
    _uvs_lock=no
    _uvs_stale=no
    if [ -d "$LOCK" ]; then
        _uvs_lock=yes
        _uvs_pid=$(cat "$LOCK/pid" 2>/dev/null)
        case "$_uvs_pid" in
            ''|*[!0-9]*) _uvs_stale=yes ;;
            *)
                if kill -0 "$_uvs_pid" 2>/dev/null; then
                    _uvs_cmd=$(cat "/proc/$_uvs_pid/cmdline" 2>/dev/null | tr '\0' ' ')
                    case "$_uvs_cmd" in
                        *webui.sh*) : ;;
                        *) _uvs_stale=yes ;;
                    esac
                else
                    _uvs_stale=yes
                fi
                ;;
        esac
    fi
}

_uv_wait_scripts() {
    _uvw_i=0
    while [ "$_uvw_i" -lt 90 ]; do
        _uvw_busy=0
        for _uvw_p in /proc/[0-9]*; do
            _uvw_pid=${_uvw_p#/proc/}
            [ "$_uvw_pid" = "$$" ] && continue
            _uvw_cmd=$(cat "$_uvw_p/cmdline" 2>/dev/null | tr '\0' ' ')
            case "$_uvw_cmd" in
                *uv2800/service.sh*|*uv2800/restore.sh*|*uv2800/action.sh*)
                    _uvw_busy=1
                    break
                    ;;
            esac
        done
        [ "$_uvw_busy" = 0 ] && return 0
        sleep 1
        _uvw_i=$((_uvw_i + 1))
    done
    printf 'RESULT=busy\nCODE=busy\nDETAIL=wait_timeout\n'
    exit 3
}

_uv_require_loaded() {
    if ! _uv_loaded; then
        printf 'RESULT=fail\nCODE=module_not_loaded\n'
        exit 1
    fi
}

_uv_require_enabled() {
    if [ -f "$MOD/disable" ]; then
        printf 'RESULT=fail\nCODE=module_disabled\n'
        exit 1
    fi
}

