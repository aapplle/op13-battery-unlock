#!/system/bin/sh
# KernelSU 在启动/late-load 的 prune 阶段调用本脚本，随后仍会删除模块目录。
# 非零退出用于记录失败，不能阻止框架删除；正常入口是 action.sh 一键安全卸载。
MODDIR=${0%/*}
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
BK=/data/adb/uv2800_backup
P=/sys/module/uv2800/parameters
uv_lock || exit 1
uv_log_sep "uninstall.sh 兜底清理开始"

uninstall_pending() {
    uv_restore_mark_pending
    uv_log "卸载恢复未完成：$*；保留待恢复记录、原值和策略备份"
    uv_log "KernelSU 仍会继续删除模块目录；退出码不具有阻止删除的作用"
    exit 1
}

if [ -d "$P" ]; then
    # 在线与 action/service 完全共用恢复和终末验证，不另起持锁子进程。
    uv_restore_all "$P" || uninstall_pending "${UV_RESTORE_ERROR:-共享恢复入口失败}"
    uv_record_uninstall "$UV_RESTORE_TARGET" || uninstall_pending "保存卸载验证记录失败"
    uv_log "卸载兜底已实时验证恢复为 ${UV_RESTORE_TARGET} mV"
else
    # 早启动不重载模块。历史记录只作说明，绝不冒充本次硬件验证。
    _prior=$(uv_previous_uninstall) || _prior=""
    if [ -n "$_prior" ]; then
        uv_log "上次一键卸载已验证原值 ${_prior} mV；本阶段模块未加载，未重新读取电量计"
    else
        uv_log "本阶段模块未加载，也没有可采信的上次卸载记录"
    fi
    # 服务不可用时策略库返回失败；此处不改 XML，也不删除任何恢复备份。
    _offline_status=0
    uv_policy_restore || _offline_status=1
    uv_unbind_capacity /sys/class/power_supply/battery/capacity
    uv_capacity_unbound || _offline_status=1
    if [ -z "$_prior" ] || [ "$_offline_status" != 0 ] || [ -e "$BK/restore_pending" ]; then
        uninstall_pending "早启动的历史证据或策略/挂载清理未通过"
    fi
    uv_log "早启动策略/挂载清理已确认；ADSP 仅有上次验证记录，本次未测"
fi

# 仅成功卸载才退役策略快照，避免重装后沿用过期原键；从不删除共享 XML。
# pending 的清理权属于 uv_restore_all。失败路径已在上方保留全部恢复资料。
rm -f "$BK/target_mv" "$BK/no_adsp_write" "$BK/no_real_soc" "$BK/adsp_state" \
    "$BK/policy_orig" "$BK/policy_orig_source" "$BK/applied" \
    "$BK/orig_state" "$BK/devicepolicy_orig.xml" ||
    uninstall_pending "清理运行选项或策略快照失败"
uv_log "卸载清理完成；保留原值、恢复目标、skip、卸载验证记录和日志"
