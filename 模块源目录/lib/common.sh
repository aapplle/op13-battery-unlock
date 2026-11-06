#!/system/bin/sh
# ============================================================
# uv2800 - lib/common.sh
# 纯读取/状态辅助函数；只被 webui.sh source。
# 依赖调用方已定义：BK P MOD CAP VOLT TEMP DDRC CALI VBAT CHIP CC CS CAPUE FLOOR LOG
# 不写任何状态（adsp_read 的触发读除外）。
# ============================================================

# ---------- 基础读取 ----------
_uv_num() {
    _uvn_v=$(cat "$1" 2>/dev/null | tr -d '[:space:]')
    case "$_uvn_v" in
        ''|*[!0-9]*) printf 'NA'; return 1 ;;
    esac
    while :; do
        case "$_uvn_v" in
            0?*) _uvn_v=${_uvn_v#0} ;;
            *) break ;;
        esac
    done
    case "$_uvn_v" in
        ''|*[!0-9]*) _uvn_v=0 ;;
    esac
    printf '%s' "$_uvn_v"
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

_uv_voltage_mv() {
    _uvvm_v=$(cat "$VOLT" 2>/dev/null | tr -d '[:space:]')
    case "$_uvvm_v" in
        ''|*[!0-9]*) printf 'NA'; return ;;
    esac
    _uvvm_v=$((_uvvm_v / 1000))
    if [ "$_uvvm_v" -gt 0 ] 2>/dev/null; then
        printf '%s' "$_uvvm_v"
    else
        printf 'NA'
    fi
}

_uv_temp_c() {
    _uvt_v=$(cat "$TEMP" 2>/dev/null | tr -d '[:space:]')
    case "$_uvt_v" in
        ''|*[!0-9-]*) printf 'NA'; return ;;
        -) printf 'NA'; return ;;
    esac
    if ! [ "$_uvt_v" -eq "$_uvt_v" ] 2>/dev/null; then
        printf 'NA'; return
    fi
    _uvt_s=''
    case "$_uvt_v" in
        -*) _uvt_s='-'; _uvt_v=${_uvt_v#-} ;;
    esac
    _uvt_w=$((_uvt_v / 10))
    _uvt_f=$((_uvt_v % 10))
    printf '%s%s.%s' "$_uvt_s" "$_uvt_w" "$_uvt_f"
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

_uv_read_adsp() {
    if [ ! -e "$P/adsp_read" ]; then
        printf 'NA'; return
    fi
    echo 1 > "$P/adsp_read" 2>/dev/null
    _uvra_v=$(cat "$P/adsp_read" 2>/dev/null | tr -d '[:space:]')
    case "$_uvra_v" in
        ''|*[!0-9]*) printf 'NA'; return ;;
    esac
    while :; do
        case "$_uvra_v" in
            0?*) _uvra_v=${_uvra_v#0} ;;
            *) break ;;
        esac
    done
    case "$_uvra_v" in
        ''|*[!0-9]*) _uvra_v=0 ;;
    esac
    if [ "$_uvra_v" -gt 2000 ] 2>/dev/null; then
        printf '%s' "$_uvra_v"
    else
        printf 'NA'
    fi
}

_uv_route_log() {
    _uvr_line=$(grep 'KSU_LATE_LOAD=' "$LOG" 2>/dev/null | tail -1)
    if [ -z "$_uvr_line" ]; then
        printf 'unknown'; return
    fi
    _uvr_val=$(printf '%s\n' "$_uvr_line" | sed 's/.*KSU_LATE_LOAD=//' | tr -d '[:space:]')
    case "$_uvr_val" in
        1*) printf 'late-load' ;;
        *) printf 'standard' ;;
    esac
}

_uv_profile() {
    _uvpr_v=$(dmesg 2>/dev/null | grep 'uv2800: v11 ready' | tail -1 | sed -n 's/.*profile=\[\([^]]*\)\].*/\1/p')
    if [ -z "$_uvpr_v" ]; then
        _uvpr_v=$(grep 'profile=' "$LOG" 2>/dev/null | tail -1 | sed -n 's/.*profile=\[\([^]]*\)\].*/\1/p')
    fi
    if [ -z "$_uvpr_v" ]; then
        case "$(getprop ro.build.display.id 2>/dev/null)" in
            *15.*) _uvpr_v=cos15 ;;
            *16.*|*17.*) _uvpr_v=cos16_17 ;;
        esac
    fi
    case "$_uvpr_v" in
        *"ColorOS 16"*|*"ColorOS 17"*|*cos16*|*cos17*) printf 'cos16_17' ;;
        *"ColorOS 15"*|*cos15*) printf 'cos15' ;;
        *none*) printf 'none' ;;
        *) printf 'unknown' ;;
    esac
}

_uv_orig_state() {
    _uvos_v=$(cat "$BK/orig_state" 2>/dev/null | tr -d '[:space:]')
    case "$_uvos_v" in
        existed|absent) printf '%s' "$_uvos_v" ;;
        *) printf 'NA' ;;
    esac
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

_uv_term_target() {
    # QBG 学习 term 与 AP shutdown 分离；优先读内核参数，其次落盘默认值。
    _uvtt_v=$(cat "$P/uv_term_mv" 2>/dev/null | tr -d '[:space:]')
    case "$_uvtt_v" in
        ''|*[!0-9]*) _uvtt_v=$(cat "$BK/term_mv" 2>/dev/null | tr -d '[:space:]') ;;
    esac
    case "$_uvtt_v" in
        ''|*[!0-9]*) _uvtt_v=2540 ;;
    esac
    printf '%s' "$_uvtt_v"
}

_uv_derived() {
    # 兼容旧调用：ADSP 期望值现在取学习 term，而不是 V_s。
    _uv_derived_term=$(_uv_term_target)
    printf '%s' "$_uv_derived_term"
}

_uv_mms_dir() {
    printf '/sys/devices/platform/soc/soc:oplus,mms_gauge/oplus_mms/gauge'
}

_uv_fcc_read() {
    # 设置 _uvfr_v / _uvfr_src；只读优先，C15 用 item 7 选择器读真值并恢复。
    _uvfr_v=NA
    _uvfr_src=NA
    _uvrf_v=$(dmesg 2>/dev/null | grep 'bs_update_data' | tail -1 | sed -n 's/.* fcc=\([0-9][0-9]*\).*/\1/p')
    case "$_uvrf_v" in
        ''|*[!0-9]*) ;;
        *) _uvfr_v=$_uvrf_v; _uvfr_src=bs; return ;;
    esac

    _uvg=$(_uv_mms_dir)
    if [ -w "$_uvg/item_id" ]; then
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
        _orig=$(cat "$_uvg/item_id" 2>/dev/null | tr -d '[:space:]')
        case "$_orig" in ''|*[!0-9]*) _orig=0 ;; esac
        echo 7 > "$_uvg/item_id" 2>/dev/null
        _raw=$(cat "$_uvg/data" 2>/dev/null | tr -d '[:space:]')
        [ "$_orig" -gt 0 ] 2>/dev/null && echo "$_orig" > "$_uvg/item_id" 2>/dev/null
        case "$_raw" in
            ''|*[!0-9]*) ;;
            *) _uvfr_v=$_raw; _uvfr_src=mms; echo "$_uvfr_v $_uvfr_src $_now" > "$BK/.fcc_raw" 2>/dev/null; return ;;
        esac
    fi

    _uvrf_v=$(cat "$FCC" 2>/dev/null | tr -d '[:space:]')
    case "$_uvrf_v" in
        ''|*[!0-9]*) ;;
        *) _uvfr_v=$_uvrf_v; _uvfr_src=display ;;
    esac
}

_uv_raw_fcc() {
    _uv_fcc_read
    printf '%s' "$_uvfr_v"
}

_uv_fcc_src() {
    _uv_fcc_read
    printf '%s' "$_uvfr_src"
}

_uv_parse_mv() {
    _uvp_v=${1:-}
    case "$_uvp_v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    while :; do
        case "$_uvp_v" in
            0?*) _uvp_v=${_uvp_v#0} ;;
            *) break ;;
        esac
    done
    case "$_uvp_v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ ${#_uvp_v} -le 4 ] || return 1
    [ "$_uvp_v" -ge 2800 ] 2>/dev/null || return 1
    [ "$_uvp_v" -le 3060 ] 2>/dev/null || return 1
    _UV_MV=$_uvp_v
    return 0
}

_uv_orig_ref() {
    _uvor_v=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d '[:space:]')
    case "$_uvor_v" in
        ''|*[!0-9]*) : ;;
        *)
            while :; do
                case "$_uvor_v" in
                    0?*) _uvor_v=${_uvor_v#0} ;;
                    *) break ;;
                esac
            done
            case "$_uvor_v" in
                ''|*[!0-9]*) : ;;
                *)
                    if [ "$_uvor_v" -ge 3000 ] 2>/dev/null && [ "$_uvor_v" -le 5000 ] 2>/dev/null; then
                        printf '%s' "$_uvor_v"; return 0
                    fi
                    ;;
            esac
            ;;
    esac
    _uvor_v=$(uv_dt_orig 2>/dev/null | tail -1 | tr -d '[:space:]')
    case "$_uvor_v" in
        ''|*[!0-9]*) printf 'NA'; return 1 ;;
    esac
    if [ "$_uvor_v" -lt 2000 ] 2>/dev/null || [ "$_uvor_v" -gt 5000 ] 2>/dev/null; then
        printf 'NA'; return 1
    fi
    printf '%s' "$_uvor_v"
}

