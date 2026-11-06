#!/system/bin/sh
# apply / enable 操作执行后的状态读回复核

_uv_verify_core() {
    _uvc_mv=$1
    _uvc_exp=$2
    _uvc_skip=$3
    _uvc_rc=$4

    _uvc_pt=$(_uv_num "$P/uv_target_mv")
    _uvc_adsp=$(_uv_read_adsp)
    _uvc_vbat=$(_uv_num "$VBAT")
    _uvc_skipnow=$(_uv_yesno "$BK/skip")
    _uvc_ov=$(_uv_num "$P/uv_apply")

    _uvc_tok=0
    [ "$_uvc_pt" = "$_uvc_mv" ] && _uvc_tok=1
    _uvc_aok=0
    [ "$_uvc_adsp" = "$_uvc_exp" ] && _uvc_aok=1
    _uvc_vok=0
    [ "$_uvc_vbat" = "$_uvc_mv" ] && _uvc_vok=1
    _uvc_sok=0
    [ "$_uvc_skipnow" = "$_uvc_skip" ] && _uvc_sok=1
    _uvc_ook=0
    [ "$_uvc_ov" = "1" ] && _uvc_ook=1

    _uvc_bl=$(_uv_bind_layers)
    _uvc_bg=$(_uv_bind_global)
    _uvc_nrs=$(_uv_yesno "$BK/no_real_soc")
    _uvc_np=$(_uv_yesno "$BK/no_policy")
    _uvc_applied=$(_uv_yesno "$BK/applied")

    _uvc_bexp=1
    [ "$_uvc_nrs" = yes ] && _uvc_bexp=0
    _uvc_bok=1
    if [ "$_uvc_bexp" = 1 ]; then
        if [ "$_uvc_bg" != NA ]; then
            [ "$_uvc_bg" -ge 1 ] 2>/dev/null || _uvc_bok=0
        else
            [ "$_uvc_bl" -ge 1 ] 2>/dev/null || _uvc_bok=0
        fi
    else
        [ "$_uvc_bl" = 0 ] && { [ "$_uvc_bg" = NA ] || [ "$_uvc_bg" = 0 ]; } || _uvc_bok=0
    fi

    _uvc_pok=0
    if [ "$_uvc_skipnow" = yes ] || [ "$_uvc_np" = yes ]; then
        [ "$_uvc_applied" = no ] && _uvc_pok=1
    else
        [ "$_uvc_applied" = yes ] && _uvc_pok=1
    fi

    _uvc_verify=ok
    [ "$_uvc_tok" = 1 ] && [ "$_uvc_aok" = 1 ] && [ "$_uvc_vok" = 1 ] && [ "$_uvc_sok" = 1 ] || _uvc_verify=mismatch

    if [ "$_uvc_verify" = mismatch ]; then
        _uvc_result=warn
        _uvc_code=write_failed
    elif [ "$_uvc_ook" = 0 ]; then
        _uvc_result=warn
        _uvc_code=override_failed
    elif [ "$_uvc_bok" = 0 ]; then
        _uvc_result=warn
        _uvc_code=bind_failed
    elif [ "$_uvc_pok" = 0 ]; then
        _uvc_result=warn
        _uvc_code=policy_failed
    else
        _uvc_result=ok
        _uvc_code=ok
    fi

    printf 'RESULT=%s\n' "$_uvc_result"
    printf 'CODE=%s\n' "$_uvc_code"
    printf 'VERIFY=%s\n' "$_uvc_verify"
    printf 'TARGET=%s\n' "$_uvc_mv"
    printf 'ADSP_DERIVED=%s\n' "$_uvc_exp"
    printf 'ADSP_READ=%s\n' "$_uvc_adsp"
    printf 'UV_APPLY=%s\n' "$_uvc_ov"
    printf 'OVERRIDE_OK=%s\n' "$_uvc_ook"
    printf 'VBAT_UV=%s\n' "$_uvc_vbat"
    printf 'PARAM_TARGET=%s\n' "$_uvc_pt"
    printf 'SKIP=%s\n' "$_uvc_skipnow"
    printf 'BIND_LAYERS=%s\n' "$_uvc_bl"
    printf 'BIND_GLOBAL=%s\n' "$_uvc_bg"
    printf 'NO_REAL_SOC=%s\n' "$_uvc_nrs"
    printf 'NO_POLICY=%s\n' "$_uvc_np"
    printf 'APPLIED=%s\n' "$_uvc_applied"
    printf 'TARGET_OK=%s\n' "$_uvc_tok"
    printf 'ADSP_OK=%s\n' "$_uvc_aok"
    printf 'VBAT_OK=%s\n' "$_uvc_vok"
    printf 'SKIP_OK=%s\n' "$_uvc_sok"
    printf 'BIND_OK=%s\n' "$_uvc_bok"
    printf 'POLICY_OK=%s\n' "$_uvc_pok"
    printf 'DETAIL=rc:%s\n' "${_uvc_rc:-NA}"
}
