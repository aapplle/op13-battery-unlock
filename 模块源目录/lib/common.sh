#!/system/bin/sh
# WebUI 状态读取与数值解析辅助库（由 webui.sh 加载）
# 尽量使用 POSIX shell 内建 read 与参数展开，减少高频轮询时的进程 fork 开销。

_UV_CR=$(printf '\r')
_UV_TAB=$(printf '\t')

_uv_strip_zeros_val() {
    _uvsz_v=$1
    while :; do
        case "$_uvsz_v" in
            0?*) _uvsz_v=${_uvsz_v#0} ;;
            *) break ;;
        esac
    done
    case "$_uvsz_v" in
        ''|*[!0-9]*) _uvsz_v=0 ;;
    esac
    _UV_RET=$_uvsz_v
}

_uv_strip_zeros() {
    _uv_strip_zeros_val "$1"
    printf '%s' "$_UV_RET"
}

# 单行短文件读取并去除空白/回车，结果写入 _UV_RET（零子进程开销）
_uv_read_trimmed() {
    _UV_RET=""
    [ -r "$1" ] || return 1
    IFS= read -r _uvrt_v < "$1" 2>/dev/null || [ -n "$_uvrt_v" ] || return 1
    while :; do
        case "$_uvrt_v" in
            *" "*) _uvrt_v="${_uvrt_v%% *}${_uvrt_v#* }" ;;
            *"$_UV_TAB"*) _uvrt_v="${_uvrt_v%%$_UV_TAB*}${_uvrt_v#*$_UV_TAB}" ;;
            *"$_UV_CR"*) _uvrt_v="${_uvrt_v%%$_UV_CR*}${_uvrt_v#*$_UV_CR}" ;;
            *) break ;;
        esac
    done
    _UV_RET=$_uvrt_v
    return 0
}

_uv_num_val() {
    if ! _uv_read_trimmed "$1"; then
        _UV_RET=NA; return 1
    fi
    case "$_UV_RET" in
        ''|*[!0-9]*) _UV_RET=NA; return 1 ;;
    esac
    _uv_strip_zeros_val "$_UV_RET"
    return 0
}

_uv_num() {
    _uv_num_val "$1" || { printf 'NA'; return 1; }
    printf '%s' "$_UV_RET"
}

_uv_yesno() {
    if [ -e "$1" ]; then printf 'yes'; else printf 'no'; fi
}

_uv_safe() {
    _uvsf_v=$1
    case "$_uvsf_v" in
        '') printf 'NA'; return ;;
    esac
    printf '%s' "$_uvsf_v" | tr -c 'A-Za-z0-9_.:-' '_'
}

_uv_voltage_mv_val() {
    if ! _uv_read_trimmed "$VOLT"; then
        _UV_RET=NA; return
    fi
    case "$_UV_RET" in
        ''|*[!0-9]*) _UV_RET=NA; return ;;
    esac
    _uvvm_v=$((_UV_RET / 1000))
    if [ "$_uvvm_v" -gt 0 ] 2>/dev/null; then
        _UV_RET=$_uvvm_v
    else
        _UV_RET=NA
    fi
}

_uv_voltage_mv() {
    _uv_voltage_mv_val
    printf '%s' "$_UV_RET"
}

_uv_temp_c_val() {
    if ! _uv_read_trimmed "$TEMP"; then
        _UV_RET=NA; return
    fi
    _uvt_v=$_UV_RET
    case "$_uvt_v" in
        ''|*[!0-9-]*|-) _UV_RET=NA; return ;;
    esac
    if ! [ "$_uvt_v" -eq "$_uvt_v" ] 2>/dev/null; then
        _UV_RET=NA; return
    fi
    _uvt_s=''
    case "$_uvt_v" in
        -*) _uvt_s='-'; _uvt_v=${_uvt_v#-} ;;
    esac
    _UV_RET="${_uvt_s}$((_uvt_v / 10)).$((_uvt_v % 10))"
}

_uv_temp_c() {
    _uv_temp_c_val
    printf '%s' "$_UV_RET"
}

_uv_bind_layers() {
    _uvbl_v=$(grep -c chip_soc /proc/self/mountinfo 2>/dev/null || true)
    case "$_uvbl_v" in
        ''|*[!0-9]*) _uvbl_v=0 ;;
    esac
    printf '%s' "$_uvbl_v"
}

_uv_ns_diff() {
    _uvns_a=$(readlink /proc/self/ns/mnt 2>/dev/null)
    _uvns_b=$(readlink /proc/1/ns/mnt 2>/dev/null)
    if [ -n "$_uvns_a" ] && [ -n "$_uvns_b" ] && [ "$_uvns_a" != "$_uvns_b" ]; then
        return 0
    fi
    return 1
}

_uv_bind_global() {
    if _uv_ns_diff && command -v nsenter >/dev/null 2>&1; then
        _uvbg_v=$(nsenter -t 1 -m -- grep -c chip_soc /proc/self/mountinfo 2>/dev/null || true)
        case "$_uvbg_v" in
            ''|*[!0-9]*) printf 'NA' ;;
            *) printf '%s' "$_uvbg_v" ;;
        esac
    else
        _uv_bind_layers
    fi
}

_uv_read_adsp_val() {
    if [ ! -e "$P/adsp_read" ]; then
        _UV_RET=NA; return
    fi
    echo 1 > "$P/adsp_read" 2>/dev/null
    if ! _uv_read_trimmed "$P/adsp_read"; then
        _UV_RET=NA; return
    fi
    case "$_UV_RET" in
        ''|*[!0-9]*) _UV_RET=NA; return ;;
    esac
    _uv_strip_zeros_val "$_UV_RET"
    if [ "$_UV_RET" -gt 2000 ] 2>/dev/null; then
        return
    fi
    _UV_RET=NA
}

_uv_read_adsp() {
    _uv_read_adsp_val
    printf '%s' "$_UV_RET"
}

# 单次扫描 uv2800.log，同时提取启动路线、profile 与总行数，避免重复读日志与扫 dmesg
_uv_scan_log_meta() {
    _UV_LOG_ROUTE=unknown
    _UV_LOG_PROFILE=""
    _UV_LOG_LINES=NA
    if [ ! -f "$LOG" ]; then
        return
    fi
    _uvsl_out=$(awk '
    /KSU_LATE_LOAD=/ {
        s = $0
        sub(/.*KSU_LATE_LOAD=/, "", s)
        gsub(/[[:space:]]/, "", s)
        route = (substr(s, 1, 1) == "1") ? "late-load" : "standard"
    }
    /profile=\[/ {
        p = $0
        sub(/.*profile=\[/, "", p)
        sub(/\].*/, "", p)
        prof = p
    }
    END {
        if (route == "") route = "unknown"
        printf "%s|%s|%d\n", route, prof, NR
    }' "$LOG" 2>/dev/null)
    if [ -n "$_uvsl_out" ]; then
        IFS='|' read -r _UV_LOG_ROUTE _UV_LOG_PROFILE _UV_LOG_LINES <<EOF
$_uvsl_out
EOF
        [ -n "$_UV_LOG_ROUTE" ] || _UV_LOG_ROUTE=unknown
        case "$_UV_LOG_LINES" in ''|*[!0-9]*) _UV_LOG_LINES=NA ;; esac
    fi
}

_uv_route_log() {
    _uv_scan_log_meta
    printf '%s' "$_UV_LOG_ROUTE"
}

_uv_normalize_profile() {
    case "$1" in
        *"ColorOS 16"*|*"ColorOS 17"*|*cos16*|*cos17*) _UV_RET=cos16_17 ;;
        *"ColorOS 15"*|*cos15*) _UV_RET=cos15 ;;
        *none*) _UV_RET=none ;;
        *) _UV_RET=unknown ;;
    esac
}

# 优先使用已扫描的日志 profile（避免高频扫 dmesg），缺失时再查 dmesg 与系统属性
_uv_profile_val() {
    _uvpr_v=${1:-}
    if [ -z "$_uvpr_v" ] && [ -f "$LOG" ]; then
        _uvpr_v=$(grep 'profile=' "$LOG" 2>/dev/null | tail -1 | sed -n 's/.*profile=\[\([^]]*\)\].*/\1/p')
    fi
    if [ -z "$_uvpr_v" ]; then
        _uvpr_v=$(dmesg 2>/dev/null | grep 'uv2800: v12 ready' | tail -1 | sed -n 's/.*profile=\[\([^]]*\)\].*/\1/p')
    fi
    if [ -z "$_uvpr_v" ]; then
        case "$(getprop ro.build.display.id 2>/dev/null)" in
            *15.*) _uvpr_v=cos15 ;;
            *16.*|*17.*) _uvpr_v=cos16_17 ;;
        esac
    fi
    _uv_normalize_profile "$_uvpr_v"
}

_uv_profile() {
    _uv_profile_val ""
    printf '%s' "$_UV_RET"
}

_uv_orig_state_val() {
    if _uv_read_trimmed "$BK/orig_state"; then
        case "$_UV_RET" in
            existed|absent) return ;;
        esac
    fi
    _UV_RET=NA
}

_uv_orig_state() {
    _uv_orig_state_val
    printf '%s' "$_UV_RET"
}

_uv_log_lines() {
    if [ ! -f "$LOG" ]; then
        printf 'NA'; return
    fi
    _uvll_v=$(wc -l < "$LOG" 2>/dev/null | tr -d '[:space:]')
    case "$_uvll_v" in
        ''|*[!0-9]*) printf 'NA' ;;
        *) printf '%s' "$_uvll_v" ;;
    esac
}

_uv_loaded() {
    if [ -e "$P/adsp_write" ] || [ -d /sys/module/uv2800 ]; then
        return 0
    fi
    return 1
}

# 纯公式派生期望的电量计学习终止电压（严格由入参 V_s 计算，不读取内核当前状态）
_uv_derived() {
    _uvd_v=${1:-}
    if command -v uv_derive_term_mv >/dev/null 2>&1; then
        uv_derive_term_mv "$_uvd_v"
        return
    fi
    case "$_uvd_v" in
        ''|*[!0-9]*) printf '2540'; return ;;
    esac
    if [ "$_uvd_v" -lt 3060 ] 2>/dev/null; then
        _uvd_t=$((2 * _uvd_v - 3060))
    else
        _uvd_t=$_uvd_v
    fi
    [ "$_uvd_t" -lt 2000 ] 2>/dev/null && _uvd_t=2000
    [ "$_uvd_t" -gt 5000 ] 2>/dev/null && _uvd_t=5000
    printf '%s' "$_uvd_t"
}

_uv_mms_dir() {
    printf '/sys/devices/platform/soc/soc:oplus,mms_gauge/oplus_mms/gauge'
}

# 读取电量计 FCC：
# 优先命中 60 秒内的缓存（bs 与 mms 均缓存，减少 dmesg 与 sysfs 轮询开销）；
# 否则依次尝试 dmesg 的 bs_update_data、oplus_mms 的 item 7（GAUGE_ITEM_FCC），
# 最后回退到 sysfs 的 battery_fcc 显示值。
_uv_fcc_read() {
    _uvfr_v=NA
    _uvfr_src=NA
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    if [ -f "$BK/.fcc_raw" ]; then
        read _cv _cs _ct < "$BK/.fcc_raw" 2>/dev/null
        case "$_cv" in ''|*[!0-9]*) _cv=NA ;; esac
        case "$_ct" in ''|*[!0-9]*) _ct=0 ;; esac
        _age=$((_now - _ct))
        if [ "$_cv" != NA ] && [ "$_now" -gt 0 ] 2>/dev/null && [ "$_age" -ge 0 ] 2>/dev/null && [ "$_age" -lt 60 ] 2>/dev/null; then
            _uvfr_v=$_cv
            _uvfr_src=$_cs
            [ -n "$_uvfr_src" ] || _uvfr_src=mms
            return
        fi
    fi

    _uvrf_v=$(dmesg 2>/dev/null | grep 'bs_update_data' | tail -1 | sed -n 's/.* fcc=\([0-9][0-9]*\).*/\1/p')
    case "$_uvrf_v" in
        ''|*[!0-9]*) ;;
        *)
            _uvfr_v=$_uvrf_v
            _uvfr_src=bs
            [ "$_now" -gt 0 ] 2>/dev/null && printf '%s %s %s\n' "$_uvfr_v" "$_uvfr_src" "$_now" > "$BK/.fcc_raw" 2>/dev/null
            return
            ;;
    esac

    _uvg=/sys/devices/platform/soc/soc:oplus,mms_gauge/oplus_mms/gauge
    if [ -w "$_uvg/item_id" ]; then
        _orig=""
        if _uv_read_trimmed "$_uvg/item_id"; then
            case "$_UV_RET" in ''|*[!0-9]*) _orig="" ;; *) _orig=$_UV_RET ;; esac
        fi
        echo 7 > "$_uvg/item_id" 2>/dev/null
        _raw=""
        _uv_read_trimmed "$_uvg/data" && _raw=$_UV_RET
        [ -n "$_orig" ] && [ "$_orig" != "7" ] && echo "$_orig" > "$_uvg/item_id" 2>/dev/null
        case "$_raw" in
            ''|*[!0-9]*) ;;
            *)
                _uvfr_v=$_raw
                _uvfr_src=mms
                [ "$_now" -gt 0 ] 2>/dev/null && printf '%s %s %s\n' "$_uvfr_v" "$_uvfr_src" "$_now" > "$BK/.fcc_raw" 2>/dev/null
                return
                ;;
        esac
    fi

    if _uv_read_trimmed "$FCC"; then
        case "$_UV_RET" in
            ''|*[!0-9]*) ;;
            *) _uvfr_v=$_UV_RET; _uvfr_src=display ;;
        esac
    fi
}

_uv_parse_mv() {
    _uvp_v=${1:-}
    case "$_uvp_v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _uv_strip_zeros_val "$_uvp_v"
    _uvp_v=$_UV_RET
    [ ${#_uvp_v} -le 4 ] || return 1
    [ "$_uvp_v" -ge 2800 ] 2>/dev/null || return 1
    [ "$_uvp_v" -le 3060 ] 2>/dev/null || return 1
    _UV_MV=$_uvp_v
    return 0
}

_uv_orig_ref() {
    if _uv_read_trimmed "$BK/adsp_orig.txt"; then
        case "$_UV_RET" in
            ''|*[!0-9]*) : ;;
            *)
                _uv_strip_zeros_val "$_UV_RET"
                if [ "$_UV_RET" -ge 3000 ] 2>/dev/null && [ "$_UV_RET" -le 5000 ] 2>/dev/null; then
                    printf '%s' "$_UV_RET"; return 0
                fi
                ;;
        esac
    fi
    _uvor_v=$(uv_dt_orig 2>/dev/null | tail -1 | tr -d '[:space:]')
    case "$_uvor_v" in
        ''|*[!0-9]*) printf 'NA'; return 1 ;;
    esac
    if [ "$_uvor_v" -lt 2000 ] 2>/dev/null || [ "$_uvor_v" -gt 5000 ] 2>/dev/null; then
        printf 'NA'; return 1
    fi
    printf '%s' "$_uvor_v"
}
