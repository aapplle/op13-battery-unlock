#!/system/bin/sh
# Shared restore transaction. Caller holds uv_lock; source has no side effects.

# Always use current validated DT/sysfs inputs. adsp_orig.txt is history only.
uv_restore_target() {
    _rt_value=$(uv_dt_orig) || return 1
    case "$_rt_value" in [23][0-9][0-9][0-9]) ;; *) return 1 ;; esac
    [ "$_rt_value" -ge 2900 ] && [ "$_rt_value" -le 3500 ] || return 1
    echo "$_rt_value"
}

uv_restore_mark_pending() {
    mkdir -p "$UV_BK" && touch "$UV_BK/skip" "$UV_BK/restore_pending" || return 1
    rm -f "$UV_BK/uninstall_verified" "$UV_BK/uninstall_verified.tmp" \
        "$UV_BK/adsp_state" "$UV_BK/adsp_state.tmp"
}

uv_restore_abort() {
    UV_RESTORE_ERROR=$*
    uv_restore_mark_pending || uv_log "错误：保存待恢复状态失败"
    uv_log "恢复未完成：$UV_RESTORE_ERROR"
    return 1
}

# A temperature/cycle-table transition during restore must not yield success.
uv_restore_check_live() {
    _rc_target=$(uv_restore_target) || return 1
    [ "$_rc_target" = "$1" ] || return 1
    uv_restore_voltage "$1" >/dev/null
}

uv_restore_check_hardware() {
    _rh_target=$1; _rh_p=$2
    _rh_read=$(uv_read_adsp "$_rh_p") || return 1
    [ "$_rh_read" = "$_rh_target" ] &&
        [ "$(cat "$_rh_p/uv_target_mv" 2>/dev/null)" = "$_rh_target" ] &&
        [ "$(cat "$_rh_p/uv_adsp_mv" 2>/dev/null)" = "$_rh_target" ] &&
        [ "$(cat "$_rh_p/resume" 2>/dev/null)" = 0 ] &&
        [ "$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)" = "$_rh_target" ]
}

# Only this online path clears restore_pending. Success sets UV_RESTORE_TARGET;
# failure sets UV_RESTORE_ERROR. All callers hold the shared file lock.
uv_restore_all() {
    _restore_p=${1:-/sys/module/uv2800/parameters}
    UV_RESTORE_TARGET=""; UV_RESTORE_ERROR=""
    uv_restore_mark_pending || { UV_RESTORE_ERROR="保存待恢复状态失败"; return 1; }
    UV_RESTORE_TARGET=$(uv_restore_target) || { uv_restore_abort "实时原厂目标计算失败，未采用历史备份"; return 1; }
    uv_restore_check_live "$UV_RESTORE_TARGET" || { uv_restore_abort "电压不足、未知或实时目标发生变化，未写恢复参数"; return 1; }
    [ -d "$_restore_p" ] || { uv_restore_abort "内核恢复接口未加载"; return 1; }

    # Read-only readiness polling; recheck voltage and target after the wait.
    _restore_wait=0
    while ! uv_policy_read >/dev/null; do
        _restore_wait=$((_restore_wait+1))
        [ "$_restore_wait" -lt 15 ] || { uv_restore_abort "设备策略服务未就绪或返回无效响应"; return 1; }
        sleep 1
    done
    uv_restore_check_live "$UV_RESTORE_TARGET" || { uv_restore_abort "等待后电压或实时目标复核失败"; return 1; }

    # Preserve invalid historical evidence; never use it to choose the target.
    if [ -f "$UV_BK/adsp_orig.txt" ]; then
        _restore_old=$(cat "$UV_BK/adsp_orig.txt" 2>/dev/null)
        case "$_restore_old" in
            [23][0-9][0-9][0-9])
                if [ "$_restore_old" -lt 2900 ] || [ "$_restore_old" -gt 3500 ]; then
                    mv -f "$UV_BK/adsp_orig.txt" "$UV_BK/adsp_orig.bad" || { uv_restore_abort "保存异常历史记录失败"; return 1; }
                elif [ "$_restore_old" != "$UV_RESTORE_TARGET" ]; then
                    uv_log "历史原值 ${_restore_old} mV 与实时目标 ${UV_RESTORE_TARGET} mV 不同，采用实时目标并保留历史记录"
                fi ;;
            *) mv -f "$UV_BK/adsp_orig.txt" "$UV_BK/adsp_orig.bad" || { uv_restore_abort "保存异常历史记录失败"; return 1; } ;;
        esac
    fi

    uv_set_targets "$UV_RESTORE_TARGET" "$UV_RESTORE_TARGET" "$_restore_p" || { uv_restore_abort "恢复 hook 参数设置或校验失败"; return 1; }
    _restore_read=$(uv_read_adsp "$_restore_p") || _restore_read=""
    if [ -z "$_restore_read" ]; then
        uv_capture_dev
        sleep 1
        _restore_read=$(uv_read_adsp "$_restore_p") || _restore_read=""
    fi
    [ -n "$_restore_read" ] || { uv_restore_abort "电量计读取失败，待恢复状态保留"; return 1; }
    uv_restore_check_live "$UV_RESTORE_TARGET" || { uv_restore_abort "回写前电压或实时目标复核失败"; return 1; }
    if [ "$_restore_read" != "$UV_RESTORE_TARGET" ]; then
        echo "$UV_RESTORE_TARGET" > "$_restore_p/adsp_write" || { uv_restore_abort "电量计回写失败"; return 1; }
    fi
    uv_restore_check_hardware "$UV_RESTORE_TARGET" "$_restore_p" || { uv_restore_abort "电量计或 hook 实时读回不一致"; return 1; }

    uv_policy_restore || { uv_restore_abort "设备策略恢复或实际读回失败"; return 1; }
    uv_unbind_capacity /sys/class/power_supply/battery/capacity
    uv_capacity_unbound || { uv_restore_abort "电量挂载仍有残留或 mountinfo 读取失败"; return 1; }
    uv_restore_check_live "$UV_RESTORE_TARGET" || { uv_restore_abort "结束前电压或实时目标发生变化"; return 1; }
    uv_restore_check_hardware "$UV_RESTORE_TARGET" "$_restore_p" || { uv_restore_abort "结束前硬件读回失败"; return 1; }

    echo "$UV_RESTORE_TARGET" > "$UV_BK/restore_target_mv.tmp" &&
        mv -f "$UV_BK/restore_target_mv.tmp" "$UV_BK/restore_target_mv" || { uv_restore_abort "保存实时恢复目标失败"; return 1; }
    echo "$UV_RESTORE_TARGET" > "$UV_BK/adsp_state.tmp" &&
        mv -f "$UV_BK/adsp_state.tmp" "$UV_BK/adsp_state" || { uv_restore_abort "保存硬件验证记录失败"; return 1; }
    rm -f "$UV_BK/target_mv" "$UV_BK/no_adsp_write" || { uv_restore_abort "清理运行配置失败"; return 1; }
    rm -f "$UV_BK/restore_pending" || { uv_restore_abort "清理待恢复标记失败"; return 1; }
    uv_log "完整恢复已验证：实时目标 ${UV_RESTORE_TARGET} mV、设备策略和挂载均通过"
    return 0
}
