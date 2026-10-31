#!/system/bin/sh
# ============================================================
# uv2800 - webui.sh（WebUI 薄后端 / CLI）
#
# 只调用既有脚本与 log.sh 里的既有函数；不复制 ADSP/策略/bind 算法。
# 所有异步输出都是 ASCII key=value；自由文本只走 log（同步 exec）。
# ============================================================

case "$0" in
    */*) _uv_dir=${0%/*} ;;
    *)   _uv_dir=. ;;
esac
MODDIR=$(cd "$_uv_dir" 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/uv2800

BK=/data/adb/uv2800_backup
LOCK=$BK/.webui.lock
LOG=$BK/uv2800.log
LAST=$BK/.webui.last.log
P=/sys/module/uv2800/parameters
MOD=/data/adb/modules/uv2800
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

B=/sys/class/oplus_chg/battery
CAP=/sys/class/power_supply/battery/capacity
VOLT=/sys/class/power_supply/battery/voltage_now
TEMP=/sys/class/power_supply/battery/temp
DDRC=/sys/devices/virtual/oplus_chg/common/deep_dischg_counts
CALI=/sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali
VBAT=$B/vbat_uv
CHIP=$B/chip_soc
CC=$B/battery_cc
BTYPE=$B/battery_type
FLOOR=3060

[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_dt_orig >/dev/null 2>&1 || uv_dt_orig() { return 1; }
command -v uv_capture_dev >/dev/null 2>&1 || uv_capture_dev() { return 1; }
klog() {
    _m="uv2800: $*"
    echo "$_m" > /dev/kmsg 2>/dev/null
    mkdir -p "$BK" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S')] $_m" >> "$LOG" 2>/dev/null
}
[ -f "$MODDIR/lib/features.sh" ] && . "$MODDIR/lib/features.sh"

# ---------- 公共读取/状态函数（lib/common.sh） ----------
if [ ! -f "$MODDIR/lib/common.sh" ]; then
    printf 'RESULT=fail\nCODE=internal\nDETAIL=common_missing\n'
    exit 1
fi
. "$MODDIR/lib/common.sh"

# ---------- 锁 / 等待 / 前置检查（lib/lock.sh） ----------
if [ ! -f "$MODDIR/lib/lock.sh" ]; then
    printf 'RESULT=fail\nCODE=internal\nDETAIL=lock_missing\n'
    exit 1
fi
. "$MODDIR/lib/lock.sh"

# ---------- 跑 service.sh（lib/route.sh） ----------
if [ ! -f "$MODDIR/lib/route.sh" ]; then
    printf 'RESULT=fail\nCODE=internal\nDETAIL=route_missing\n'
    exit 1
fi
. "$MODDIR/lib/route.sh"

# ---------- 复核（lib/verify.sh） ----------
if [ ! -f "$MODDIR/lib/verify.sh" ]; then
    printf 'RESULT=fail\nCODE=internal\nDETAIL=verify_missing\n'
    exit 1
fi
. "$MODDIR/lib/verify.sh"

# ---------- 子命令 ----------
cmd_status() {
    _uvs_loaded=0
    _uv_loaded && _uvs_loaded=1
    _uvs_disabled=0
    [ -f "$MOD/disable" ] && _uvs_disabled=1
    _uvs_removing=0
    [ -f "$MOD/remove" ] && _uvs_removing=1

    _uvs_skip=$(_uv_yesno "$BK/skip")
    _uvs_nrs=$(_uv_yesno "$BK/no_real_soc")
    _uvs_np=$(_uv_yesno "$BK/no_policy")
    _uvs_naw=$(_uv_yesno "$BK/no_adsp_write")
    _uvs_bad=$(_uv_yesno "$BK/adsp_orig.bad")
    _uvs_applied=$(_uv_yesno "$BK/applied")

    _uvs_tfile=$(_uv_num "$BK/target_mv")
    _uvs_pt=$(_uv_num "$P/uv_target_mv")
    _uvs_pa=$(_uv_num "$P/uv_adsp_mv")
    _uvs_adsp=$(_uv_read_adsp)
    _uvs_vbat=$(_uv_num "$VBAT")
    _uvs_cap=$(_uv_num "$CAP")
    _uvs_chip=$(_uv_num "$CHIP")
    _uvs_volt=$(_uv_voltage_mv)
    _uvs_temp=$(_uv_temp_c)
    _uvs_counts=$(_uv_num "$DDRC")
    _uvs_cc=$(_uv_num "$CC")
    _uvs_cali=$(_uv_num "$CALI")
    _uvs_orig=$(_uv_num "$BK/adsp_orig.txt")
    _uvs_state=$(_uv_num "$BK/adsp_state")
    _uvs_ostate=$(_uv_orig_state)
    _uvs_resume=$(_uv_num "$P/resume")
    _uvs_bl=$(_uv_bind_layers)
    _uvs_bg=$(_uv_bind_global)
    _uvs_route=$(_uv_route_log)
    _uvs_profile=$(_uv_profile)
    _uvs_lines=$(_uv_log_lines)
    _uv_lock_state

    if [ "$_uvs_loaded" = 0 ]; then
        _uvs_mode=unloaded
    elif [ "$_uvs_disabled" = 1 ]; then
        _uvs_mode=disabled
    elif [ "$_uvs_skip" = yes ]; then
        _uvs_mode=factory
    else
        _uvs_mode=decoupled
    fi

    _uvs_te=NA
    case "$_uvs_mode" in
        decoupled)
            if [ "$_uvs_pt" != NA ]; then
                _uvs_te=$_uvs_pt
            elif [ "$_uvs_tfile" != NA ]; then
                _uvs_te=$_uvs_tfile
            else
                _uvs_te=2800
            fi
            ;;
        factory)
            if [ "$_uvs_pt" != NA ]; then
                _uvs_te=$_uvs_pt
            elif [ "$_uvs_orig" != NA ]; then
                _uvs_te=$_uvs_orig
            fi
            ;;
    esac

    if [ "$_uvs_mode" = decoupled ] && [ "$_uvs_te" != NA ]; then
        _uvs_derived=$(_uv_derived "$_uvs_te")
    else
        _uvs_derived=NA
    fi

    if [ "$_uvs_mode" = factory ] && [ "$_uvs_orig" != NA ]; then
        _uvs_exp=$_uvs_orig
    elif [ "$_uvs_mode" = decoupled ]; then
        _uvs_exp=$_uvs_derived
    else
        _uvs_exp=NA
    fi

    if [ "$_uvs_adsp" != NA ] && [ "$_uvs_exp" != NA ]; then
        if [ "$_uvs_adsp" = "$_uvs_exp" ]; then _uvs_am=0; else _uvs_am=1; fi
    else
        _uvs_am=NA
    fi

    if [ "$_uvs_mode" = factory ] || [ "$_uvs_nrs" = yes ]; then
        _uvs_bexp=0
    elif [ "$_uvs_mode" = decoupled ]; then
        _uvs_bexp=1
    else
        _uvs_bexp=NA
    fi

    if [ "$_uvs_bexp" = NA ]; then
        _uvs_bm=NA
    else
        if [ "$_uvs_bg" != NA ]; then _uvs_act=$_uvs_bg; else _uvs_act=$_uvs_bl; fi
        case "$_uvs_bexp" in
            0) if [ "$_uvs_act" = 0 ]; then _uvs_bm=0; else _uvs_bm=1; fi ;;
            1) if [ "$_uvs_act" -ge 1 ] 2>/dev/null; then _uvs_bm=0; else _uvs_bm=1; fi ;;
        esac
    fi

    if [ "$_uvs_skip" = yes ] || [ "$_uvs_np" = yes ]; then
        _uvs_policy=restored
    elif [ "$_uvs_applied" = yes ]; then
        _uvs_policy=applied
    else
        _uvs_policy=unknown
    fi

    _uvs_low=NA
    if [ "$_uvs_volt" != NA ] || [ "$_uvs_cap" != NA ]; then
        _uvs_low=0
        if [ "$_uvs_volt" != NA ] && [ "$_uvs_volt" -lt 3300 ] 2>/dev/null; then _uvs_low=1; fi
        if [ "$_uvs_cap" != NA ] && [ "$_uvs_cap" -lt 30 ] 2>/dev/null; then _uvs_low=1; fi
    fi

    _uvs_ver=$(sed -n 's/^version=//p' "$MOD/module.prop" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -n "$_uvs_ver" ] || _uvs_ver=NA
    _uvs_vcode=$(sed -n 's/^versionCode=//p' "$MOD/module.prop" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -n "$_uvs_vcode" ] || _uvs_vcode=NA

    _uvs_enabled=1
    if [ -f "$MOD/disable" ] || [ ! -f "$MOD/module.prop" ]; then _uvs_enabled=0; fi

    printf 'RESULT=ok\n'
    printf 'MODE=%s\n' "$_uvs_mode"
    printf 'MODULE_LOADED=%s\n' "$_uvs_loaded"
    printf 'MODULE_ENABLED=%s\n' "$_uvs_enabled"
    printf 'MODULE_REMOVING=%s\n' "$_uvs_removing"
    printf 'VERSION=%s\n' "$(_uv_safe "$_uvs_ver")"
    printf 'VERSION_CODE=%s\n' "$(_uv_safe "$_uvs_vcode")"
    printf 'PROFILE=%s\n' "$_uvs_profile"
    printf 'ROUTE=%s\n' "$_uvs_route"
    printf 'TARGET_FILE=%s\n' "$_uvs_tfile"
    printf 'PARAM_TARGET=%s\n' "$_uvs_pt"
    printf 'PARAM_ADSP=%s\n' "$_uvs_pa"
    printf 'TARGET_EFFECTIVE=%s\n' "$_uvs_te"
    printf 'ADSP_DERIVED=%s\n' "$_uvs_derived"
    printf 'ADSP_READ=%s\n' "$_uvs_adsp"
    printf 'EXPECTED_ADSP=%s\n' "$_uvs_exp"
    printf 'ADSP_MISMATCH=%s\n' "$_uvs_am"
    printf 'VBAT_UV=%s\n' "$_uvs_vbat"
    printf 'CAPACITY=%s\n' "$_uvs_cap"
    printf 'CHIP_SOC=%s\n' "$_uvs_chip"
    printf 'VOLTAGE_MV=%s\n' "$_uvs_volt"
    printf 'TEMP_C=%s\n' "$_uvs_temp"
    printf 'COUNTS=%s\n' "$_uvs_counts"
    printf 'CC=%s\n' "$_uvs_cc"
    printf 'CALI=%s\n' "$_uvs_cali"
    printf 'SKIP=%s\n' "$_uvs_skip"
    printf 'NO_REAL_SOC=%s\n' "$_uvs_nrs"
    printf 'NO_POLICY=%s\n' "$_uvs_np"
    printf 'NO_ADSP_WRITE=%s\n' "$_uvs_naw"
    printf 'ADSP_ORIG=%s\n' "$_uvs_orig"
    printf 'ADSP_ORIG_BAD=%s\n' "$_uvs_bad"
    printf 'ADSP_STATE=%s\n' "$_uvs_state"
    printf 'ORIG_STATE=%s\n' "$_uvs_ostate"
    printf 'APPLIED=%s\n' "$_uvs_applied"
    printf 'POLICY=%s\n' "$_uvs_policy"
    printf 'BIND_LAYERS=%s\n' "$_uvs_bl"
    printf 'BIND_GLOBAL=%s\n' "$_uvs_bg"
    printf 'BIND_EXPECTED=%s\n' "$_uvs_bexp"
    printf 'BIND_MISMATCH=%s\n' "$_uvs_bm"
    printf 'RESUME=%s\n' "$_uvs_resume"
    printf 'BATTERY_LOW=%s\n' "$_uvs_low"
    printf 'LOCK=%s\n' "$_uvs_lock"
    printf 'STALE_LOCK=%s\n' "$_uvs_stale"
    printf 'LOG_LINES=%s\n' "$_uvs_lines"
}

cmd_log() {
    _uvlg_n=${1:-200}
    case "$_uvlg_n" in
        ''|*[!0-9]*) printf 'ERROR invalid_n\n'; exit 1 ;;
    esac
    [ "$_uvlg_n" -lt 1 ] && _uvlg_n=1
    [ "$_uvlg_n" -gt 500 ] && _uvlg_n=500
    if [ ! -f "$LOG" ]; then
        printf 'ERROR log_missing\n'; exit 1
    fi
    tail -n "$_uvlg_n" "$LOG"
}

cmd_read_adsp() {
    _uv_require_loaded
    _uvrd_v=$(_uv_read_adsp)
    if [ "$_uvrd_v" = NA ]; then
        printf 'RESULT=warn\nCODE=adsp_not_ready\nADSP_READ=NA\nVALUE=NA\n'
        exit 0
    fi
    printf 'RESULT=ok\nCODE=ok\nADSP_READ=%s\nVALUE=%s\n' "$_uvrd_v" "$_uvrd_v"
}

cmd_orig() {
    _uvog_v=$(uv_dt_orig 2>/dev/null | tail -1 | tr -d '[:space:]')
    case "$_uvog_v" in
        ''|*[!0-9]*) printf 'RESULT=fail\nCODE=orig_failed\nORIG=NA\n'; exit 1 ;;
    esac
    if [ "$_uvog_v" -lt 2000 ] 2>/dev/null || [ "$_uvog_v" -gt 5000 ] 2>/dev/null; then
        printf 'RESULT=fail\nCODE=orig_failed\nORIG=NA\n'; exit 1
    fi
    printf 'RESULT=ok\nCODE=ok\nORIG=%s\n' "$_uvog_v"
}

cmd_capture_dev() {
    _uv_lock
    _uv_wait_scripts
    _uv_require_loaded
    printf 'webui capture-dev\n' > "$LAST"
    uv_capture_dev >> "$LAST" 2>&1
    _uvcd_rc=$?
    sleep 1
    _uvcd_v=$(_uv_read_adsp)
    if [ "$_uvcd_v" = NA ]; then
        printf 'RESULT=warn\nCODE=adsp_not_ready\nADSP_READ=NA\nCAPTURE_RC=%s\n' "$_uvcd_rc"
    else
        printf 'RESULT=ok\nCODE=ok\nADSP_READ=%s\nCAPTURE_RC=%s\n' "$_uvcd_v" "$_uvcd_rc"
    fi
}

cmd_apply() {
    _uv_lock
    _uv_wait_scripts
    _uv_require_loaded
    _uv_require_enabled

    if ! _uv_parse_mv "${1:-}"; then
        printf 'RESULT=fail\nCODE=invalid_value\nTARGET=NA\n'
        exit 1
    fi
    _uvap_mv=$_UV_MV

    if [ -f "$BK/skip" ]; then
        printf 'RESULT=fail\nCODE=skip_mode\nTARGET=%s\n' "$_uvap_mv"
        exit 1
    fi
    if [ -f "$BK/no_adsp_write" ]; then
        printf 'RESULT=fail\nCODE=test_marker\nTARGET=%s\n' "$_uvap_mv"
        exit 1
    fi

    if ! printf '%s\n' "$_uvap_mv" > "$BK/target_mv.tmp" 2>/dev/null; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=target_write\n'
        exit 1
    fi
    if ! mv -f "$BK/target_mv.tmp" "$BK/target_mv" 2>/dev/null; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=target_rename\n'
        exit 1
    fi

    printf 'webui apply %s\n' "$_uvap_mv" > "$LAST"
    _uv_run_service >> "$LAST" 2>&1
    _uvap_rc=$?
    _uvap_exp=$(_uv_derived "$_uvap_mv")
    _uv_verify_core "$_uvap_mv" "$_uvap_exp" "no" "$_uvap_rc"
}

cmd_enable() {
    _uv_lock
    _uv_wait_scripts
    _uv_require_loaded
    _uv_require_enabled

    if [ -f "$BK/no_adsp_write" ]; then
        printf 'RESULT=fail\nCODE=test_marker\nTARGET=NA\n'
        exit 1
    fi

    _uven_mv=2800
    if [ -n "${1:-}" ]; then
        if ! _uv_parse_mv "$1"; then
            printf 'RESULT=fail\nCODE=invalid_value\nTARGET=NA\n'
            exit 1
        fi
        _uven_mv=$_UV_MV
    else
        _uven_tf=$(_uv_num "$BK/target_mv")
        if [ "$_uven_tf" != NA ] && _uv_parse_mv "$_uven_tf"; then
            _uven_mv=$_UV_MV
        fi
    fi

    if ! printf '%s\n' "$_uven_mv" > "$BK/target_mv.tmp" 2>/dev/null; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=target_write\n'
        exit 1
    fi
    if ! mv -f "$BK/target_mv.tmp" "$BK/target_mv" 2>/dev/null; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=target_rename\n'
        exit 1
    fi
    rm -f "$BK/skip"

    printf 'webui enable %s\n' "$_uven_mv" > "$LAST"
    _uv_run_service >> "$LAST" 2>&1
    _uven_rc=$?
    _uven_exp=$(_uv_derived "$_uven_mv")
    _uv_verify_core "$_uven_mv" "$_uven_exp" "no" "$_uven_rc"
}

cmd_restore() {
    _uvrs_force=0
    for _uvrs_a in "$@"; do
        case "$_uvrs_a" in
            --force) _uvrs_force=1 ;;
            *) printf 'RESULT=fail\nCODE=invalid_value\n'; exit 1 ;;
        esac
    done

    _uv_lock
    _uv_wait_scripts
    _uv_require_loaded

    _uvrs_volt=$(_uv_voltage_mv)
    _uvrs_cap=$(_uv_num "$CAP")
    _uvrs_low=NA
    if [ "$_uvrs_volt" != NA ] || [ "$_uvrs_cap" != NA ]; then
        _uvrs_low=0
        if [ "$_uvrs_volt" != NA ] && [ "$_uvrs_volt" -lt 3300 ] 2>/dev/null; then _uvrs_low=1; fi
        if [ "$_uvrs_cap" != NA ] && [ "$_uvrs_cap" -lt 30 ] 2>/dev/null; then _uvrs_low=1; fi
    fi

    if [ "$_uvrs_low" = 1 ] && [ "$_uvrs_force" != 1 ]; then
        printf 'RESULT=fail\nCODE=low_battery\nBATTERY_LOW=1\nVOLTAGE_MV=%s\nCAPACITY=%s\n' "$_uvrs_volt" "$_uvrs_cap"
        exit 1
    fi

    if [ ! -f "$MODDIR/restore.sh" ]; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=restore_missing\n'
        exit 1
    fi

    printf 'webui restore force=%s\n' "$_uvrs_force" > "$LAST"
    sh "$MODDIR/restore.sh" >> "$LAST" 2>&1
    _uvrs_rc=$?

    _uvrs_skip=$(_uv_yesno "$BK/skip")
    _uvrs_adsp=$(_uv_read_adsp)
    _uvrs_vbat=$(_uv_num "$VBAT")
    _uvrs_bl=$(_uv_bind_layers)
    _uvrs_bg=$(_uv_bind_global)
    _uvrs_orig=$(_uv_orig_ref)

    _uvrs_skok=0
    [ "$_uvrs_skip" = yes ] && _uvrs_skok=1
    _uvrs_aok=0
    if [ "$_uvrs_orig" != NA ] && [ "$_uvrs_adsp" = "$_uvrs_orig" ]; then _uvrs_aok=1; fi
    _uvrs_vok=0
    if [ "$_uvrs_orig" != NA ] && [ "$_uvrs_vbat" = "$_uvrs_orig" ]; then _uvrs_vok=1; fi
    _uvrs_bok=1
    if [ "$_uvrs_bl" != 0 ]; then _uvrs_bok=0; fi
    if [ "$_uvrs_bg" != NA ] && [ "$_uvrs_bg" != 0 ]; then _uvrs_bok=0; fi

    if [ "$_uvrs_orig" = NA ]; then
        _uvrs_verify=na
    elif [ "$_uvrs_skok" = 1 ] && [ "$_uvrs_aok" = 1 ] && [ "$_uvrs_vok" = 1 ] && [ "$_uvrs_bok" = 1 ]; then
        _uvrs_verify=ok
    else
        _uvrs_verify=mismatch
    fi

    _uvrs_partial=0
    [ "$_uvrs_verify" = mismatch ] && _uvrs_partial=1

    if [ "$_uvrs_rc" != 0 ]; then
        _uvrs_result=fail
        _uvrs_code=restore_failed
    elif [ "$_uvrs_verify" = mismatch ]; then
        _uvrs_result=warn
        _uvrs_code=restore_verify_failed
    elif [ "$_uvrs_verify" = na ]; then
        _uvrs_result=warn
        _uvrs_code=orig_failed
    else
        _uvrs_result=ok
        _uvrs_code=ok
    fi

    printf 'RESULT=%s\n' "$_uvrs_result"
    printf 'CODE=%s\n' "$_uvrs_code"
    printf 'VERIFY=%s\n' "$_uvrs_verify"
    printf 'TARGET=NA\n'
    printf 'ORIG=%s\n' "$_uvrs_orig"
    printf 'ADSP_READ=%s\n' "$_uvrs_adsp"
    printf 'VBAT_UV=%s\n' "$_uvrs_vbat"
    printf 'SKIP=%s\n' "$_uvrs_skip"
    printf 'BIND_LAYERS=%s\n' "$_uvrs_bl"
    printf 'BIND_GLOBAL=%s\n' "$_uvrs_bg"
    printf 'BATTERY_LOW=%s\n' "$_uvrs_low"
    printf 'VOLTAGE_MV=%s\n' "$_uvrs_volt"
    printf 'CAPACITY=%s\n' "$_uvrs_cap"
    printf 'SKIP_OK=%s\n' "$_uvrs_skok"
    printf 'ADSP_OK=%s\n' "$_uvrs_aok"
    printf 'VBAT_OK=%s\n' "$_uvrs_vok"
    printf 'BIND_OK=%s\n' "$_uvrs_bok"
    printf 'PARTIAL=%s\n' "$_uvrs_partial"
    printf 'DETAIL=rc:%s\n' "$_uvrs_rc"

    if [ "$_uvrs_result" = fail ]; then exit 1; fi
}

cmd_set_real_soc() {
    _uvsr_v=${1:-}
    case "$_uvsr_v" in
        0|1) : ;;
        *) printf 'RESULT=fail\nCODE=invalid_value\n'; exit 1 ;;
    esac

    _uv_lock
    _uv_wait_scripts
    _uv_require_loaded
    _uv_require_enabled

    if [ -f "$BK/skip" ]; then
        printf 'RESULT=fail\nCODE=skip_mode\nNO_REAL_SOC=%s\n' "$(_uv_yesno "$BK/no_real_soc")"
        exit 1
    fi
    if ! command -v feature_real_soc_bind >/dev/null 2>&1; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=features_missing\n'
        exit 1
    fi

    if [ "$_uvsr_v" = 0 ]; then
        touch "$BK/no_real_soc"
        feature_real_soc_unbind
        _uvsr_rc=$?
    else
        rm -f "$BK/no_real_soc"
        feature_real_soc_bind
        _uvsr_rc=$?
    fi

    printf 'webui set-real-soc %s\n' "$_uvsr_v" > "$LAST"

    _uvsr_nrs=$(_uv_yesno "$BK/no_real_soc")
    _uvsr_bl=$(_uv_bind_layers)
    _uvsr_bg=$(_uv_bind_global)
    _uvsr_exp=1
    [ "$_uvsr_v" = 0 ] && _uvsr_exp=0

    _uvsr_ok=1
    if [ "$_uvsr_exp" = 1 ]; then
        if [ "$_uvsr_bg" != NA ]; then
            [ "$_uvsr_bg" -ge 1 ] 2>/dev/null || _uvsr_ok=0
        else
            [ "$_uvsr_bl" -ge 1 ] 2>/dev/null || _uvsr_ok=0
        fi
    else
        [ "$_uvsr_bl" = 0 ] && { [ "$_uvsr_bg" = NA ] || [ "$_uvsr_bg" = 0 ]; } || _uvsr_ok=0
    fi

    if [ "$_uvsr_ok" = 1 ]; then
        _uvsr_result=ok
        _uvsr_code=ok
        _uvsr_verify=ok
    else
        _uvsr_result=warn
        _uvsr_code=bind_failed
        _uvsr_verify=mismatch
    fi

    printf 'RESULT=%s\n' "$_uvsr_result"
    printf 'CODE=%s\n' "$_uvsr_code"
    printf 'VERIFY=%s\n' "$_uvsr_verify"
    printf 'NO_REAL_SOC=%s\n' "$_uvsr_nrs"
    printf 'BIND_EXPECTED=%s\n' "$_uvsr_exp"
    printf 'BIND_LAYERS=%s\n' "$_uvsr_bl"
    printf 'BIND_GLOBAL=%s\n' "$_uvsr_bg"
    printf 'BIND_OK=%s\n' "$_uvsr_ok"
    printf 'SKIP=%s\n' "$(_uv_yesno "$BK/skip")"
    printf 'DETAIL=rc:%s\n' "$_uvsr_rc"
}

cmd_set_policy() {
    _uvsp_v=${1:-}
    case "$_uvsp_v" in
        on|1) _uvsp_v=1 ;;
        off|0) _uvsp_v=0 ;;
        *) printf 'RESULT=fail\nCODE=invalid_value\n'; exit 1 ;;
    esac

    _uv_lock
    _uv_wait_scripts
    _uv_require_loaded
    _uv_require_enabled

    if [ -f "$BK/skip" ]; then
        printf 'RESULT=fail\nCODE=skip_mode\nNO_POLICY=%s\n' "$(_uv_yesno "$BK/no_policy")"
        exit 1
    fi
    if ! command -v feature_policy_apply >/dev/null 2>&1 || ! command -v feature_policy_restore >/dev/null 2>&1; then
        printf 'RESULT=fail\nCODE=internal\nDETAIL=features_missing\n'
        exit 1
    fi

    if [ "$_uvsp_v" = 1 ]; then
        rm -f "$BK/no_policy"
        feature_policy_apply
        _uvsp_rc=$?
        _uvsp_exp=applied
    else
        touch "$BK/no_policy"
        feature_policy_restore
        _uvsp_rc=$?
        _uvsp_exp=restored
    fi

    printf 'webui policy %s\n' "$_uvsp_v" > "$LAST"

    _uvsp_np=$(_uv_yesno "$BK/no_policy")
    _uvsp_ap=$(_uv_yesno "$BK/applied")
    _uvsp_os=$(_uv_orig_state)

    _uvsp_ok=1
    if [ "$_uvsp_v" = 1 ]; then
        [ "$_uvsp_np" = no ] && [ "$_uvsp_ap" = yes ] || _uvsp_ok=0
    else
        [ "$_uvsp_np" = yes ] && [ "$_uvsp_ap" = no ] || _uvsp_ok=0
    fi
    [ "$_uvsp_rc" = 0 ] || _uvsp_ok=0

    if [ "$_uvsp_ok" = 1 ]; then
        _uvsp_result=ok
        _uvsp_code=ok
        _uvsp_verify=ok
    else
        _uvsp_result=warn
        _uvsp_code=policy_failed
        _uvsp_verify=mismatch
    fi

    printf 'RESULT=%s\n' "$_uvsp_result"
    printf 'CODE=%s\n' "$_uvsp_code"
    printf 'VERIFY=%s\n' "$_uvsp_verify"
    printf 'POLICY=%s\n' "$_uvsp_exp"
    printf 'NO_POLICY=%s\n' "$_uvsp_np"
    printf 'APPLIED=%s\n' "$_uvsp_ap"
    printf 'ORIG_STATE=%s\n' "$_uvsp_os"
    printf 'DETAIL=rc:%s\n' "$_uvsp_rc"
}

# ---------- 入口 ----------
case "${1:-}" in
    status)
        cmd_status
        ;;
    apply)
        shift
        cmd_apply "$@"
        ;;
    enable)
        shift
        cmd_enable "$@"
        ;;
    restore)
        shift
        cmd_restore "$@"
        ;;
    set-real-soc)
        shift
        cmd_set_real_soc "$@"
        ;;
    policy|set-policy)
        shift
        cmd_set_policy "$@"
        ;;
    log)
        shift
        cmd_log "$@"
        ;;
    read-adsp)
        cmd_read_adsp
        ;;
    orig)
        cmd_orig
        ;;
    capture-dev)
        cmd_capture_dev
        ;;
    *)
        printf 'RESULT=fail\nCODE=internal\nDETAIL=usage\n'
        exit 2
        ;;
esac
