#!/system/bin/sh
# 用户可选功能实现库（由 service.sh 和 webui.sh 共用）：
#   1. 真实电量显示（bind-mount chip_soc -> capacity，由 $BK/no_real_soc 控制）
#   2. 禁止 1% 强制超级省电（oplusdevicepolicy，由 $BK/no_policy 控制）
#   当 $BK/skip 存在时优先解绑并恢复原厂设备策略。

feature_real_soc_bind() {
    uv_unbind_capacity "$CAP" "$CAPUE"
    _frs_bound=0
    # 优先进入 PID 1 的全局挂载命名空间执行绑定，确保 system_server 可见
    if command -v nsenter >/dev/null 2>&1; then
        if nsenter -t 1 -m -- mount --bind "$CS" "$CAP" 2>/dev/null; then
            _frs_bound=1
            klog "已绑定 chip_soc -> capacity（nsenter -t 1 -m，全局命名空间）"
        fi
    fi
    if [ "$_frs_bound" = "0" ] && mount --bind "$CS" "$CAP" 2>/dev/null; then
        _frs_bound=1
        klog "已绑定 chip_soc -> capacity（当前命名空间）"
    fi
    if [ "$_frs_bound" = "1" ]; then
        echo change > "$CAPUE" 2>/dev/null
        return 0
    fi
    klog "bind mount 失败，保留官方平滑电量"
    return 1
}

feature_real_soc_unbind() {
    uv_unbind_capacity "$CAP" "$CAPUE"
}

feature_real_soc_sync() {
    if [ -f "$BK/no_real_soc" ]; then
        feature_real_soc_unbind
        klog "检测到 no_real_soc 标记，已解绑真实电量显示"
    elif [ -f "$BK/skip" ]; then
        feature_real_soc_unbind
        klog "检测到 skip 标记（已手动恢复），已解绑真实电量显示"
    else
        feature_real_soc_bind
    fi
}

feature_policy_restore() {
    if [ -f "$BK/orig_state" ]; then
        if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ]; then
            if [ -f "$BK/devicepolicy_orig.xml" ]; then
                cp -f "$BK/devicepolicy_orig.xml" "$XML"
                chown system:system "$XML" 2>/dev/null
                chmod 600 "$XML" 2>/dev/null
            else
                klog "⚠️ 设备策略备份丢失（orig_state=existed 但 devicepolicy_orig.xml 不存在），保留当前文件"
            fi
        else
            rm -f "$XML"
        fi
    fi
    su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1
    rm -f "$BK/applied"
}

feature_policy_apply() {
    if [ ! -f "$BK/applied" ]; then
        if [ -f "$XML" ]; then
            cp -f "$XML" "$BK/devicepolicy_orig.xml"
            echo "existed" > "$BK/orig_state"
        else
            echo "absent" > "$BK/orig_state"
        fi
        touch "$BK/applied"
        klog "已备份设备策略原文件（原状态: $(cat "$BK/orig_state")）"
    fi

    _fpa_i=0; _fpa_ok=0
    while [ "$_fpa_i" -lt 60 ]; do
        _fpa_out=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1)
        case "$_fpa_out" in
            *Parcel*) _fpa_ok=1; break ;;
            *"Transaction too large"*)
                klog "⚠️ oplusdevicepolicy 出现 Transaction too large（/data/system 下策略 XML 堆积）"
                klog "   请将本日志反馈作者；本次跳过设备策略，不影响其他功能"
                _fpa_ok=-1; break
                ;;
        esac
        sleep 1
        _fpa_i=$((_fpa_i + 1))
    done
    if [ "$_fpa_ok" = "1" ]; then
        su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 true i32 1" >/dev/null 2>&1
        klog "设备策略 $KEY=true（waited ${_fpa_i}s）"
        return 0
    elif [ "$_fpa_ok" = "0" ]; then
        klog "⚠️ 等待 oplusdevicepolicy 服务超时（60s），设备策略未应用（下次开机重试）"
        return 1
    fi
    return 1
}

feature_policy_sync() {
    if [ -f "$BK/skip" ]; then
        feature_policy_restore
        klog "检测到 skip 标记（已手动恢复），已恢复设备策略"
        klog "若要重新自动应用，请 rm $BK/skip"
    elif [ -f "$BK/no_policy" ]; then
        feature_policy_restore
        klog "检测到 no_policy 标记，已恢复设备策略（仅策略，不影响 ADSP）"
    else
        feature_policy_apply
    fi
}
