#!/system/bin/sh
# One-click verified uninstall; --restore-only never schedules removal.
MODE=uninstall
case "$#:${1:-}" in
    0:) ;;
    1:--restore-only) MODE=restore ;;
    *) echo "用法：sh action.sh [--restore-only]"; exit 2 ;;
esac
MODDIR=${0%/*}
. "$MODDIR/log.sh" || exit 1
uv_lock || exit 1
uv_log_sep "action.sh 开始（mode=$MODE）"

restore_fail() {
    if [ "${UV2800_DRYRUN:-0}" != 1 ]; then
        uv_restore_mark_pending || uv_log "错误：保存恢复待办失败"
        if [ "$MODE" = uninstall ]; then
            uv_cancel_remove "$MODDIR" || uv_log "警告：撤销删除标记失败，请先在管理器取消卸载"
        fi
    fi
    uv_log "操作未完成：$*；未新增删除安排，请排除问题后重试"
    exit 1
}

if [ "${UV2800_DRYRUN:-0}" = 1 ]; then
    TARGET=$(uv_restore_target) || restore_fail "实时原厂目标计算失败，未采用历史备份"
    echo "【试运行】实时目标 ${TARGET} mV；未写设备、备份或删除标记。"
    exit 0
fi
if [ "$MODE" = uninstall ] && ! uv_cancel_remove "$MODDIR"; then
    uv_log "错误：撤销已有删除安排失败，未写设备；请先在管理器取消卸载"
    exit 1
fi

uv_restore_all /sys/module/uv2800/parameters || restore_fail "$UV_RESTORE_ERROR"
if [ "$MODE" = uninstall ]; then
    uv_record_uninstall "$UV_RESTORE_TARGET" || restore_fail "保存卸载验证记录失败"
    uv_schedule_remove "$MODDIR" || restore_fail "KernelSU 删除安排失败（恢复已执行，模块保留）"
    uv_log "一键安全卸载已安排：实时目标 ${UV_RESTORE_TARGET} mV 已验证，请重启完成删除"
    echo "一键安全卸载已安排，请重启手机。无需再点管理器的卸载按钮。"
else
    echo "回写完成！本次仅恢复，模块保留。"
    echo "重新解耦：rm /data/adb/uv2800_backup/skip 后重启。"
fi
