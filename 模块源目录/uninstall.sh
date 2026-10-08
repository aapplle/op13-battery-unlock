#!/system/bin/sh
# KernelSU 在启动/late-load 的 prune 阶段调用本脚本，随后仍会删除模块目录。
# 非零退出用于记录失败，不能阻止框架删除；正常入口是 action.sh 一键安全卸载。
MODDIR=${0%/*}
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
BK=/data/adb/uv2800_backup
P=/sys/module/uv2800/parameters
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode
_restore_rc=1

# 尚在内存时尽力复用同一恢复流程。此处尚未持锁，避免父子 flock 嵌套死锁。
# 不 insmod/rmmod，也不依赖后台或下次启动的恢复助手。
if [ -d "$P" ] && [ -f "$MODDIR/action.sh" ]; then
    UV2800_DRYRUN=0 sh "$MODDIR/action.sh" --restore-only
    _restore_rc=$?
fi
uv_lock || exit 1
uv_log_sep "uninstall.sh 兜底清理开始"
_status=0
_verified=0
if [ -d "$P" ]; then
    if [ "$_restore_rc" = 0 ]; then
        _fresh=$(uv_read_adsp "$P") || _fresh=""
        _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null)
        if [ -n "$_fresh" ] && [ "$_fresh" = "$_orig" ] &&
           [ "$(cat "$P/uv_target_mv" 2>/dev/null)" = "$_orig" ] &&
           [ "$(cat "$P/uv_adsp_mv" 2>/dev/null)" = "$_orig" ]; then
            uv_record_uninstall "$_fresh" && _verified=1
            uv_log "卸载兜底已实时验证恢复为 ${_fresh} mV"
        fi
    fi
else
    _prior=$(uv_previous_uninstall) || _prior=""
    if [ -n "$_prior" ]; then
        _verified=1
        uv_log "上次一键卸载已验证原值 ${_prior} mV；本阶段模块未加载，未重新读取电量计"
    fi
fi

# 文件/挂载清理在两种路径均可尽力完成，ADSP 恢复状态独立记录。
uv_unbind_capacity /sys/class/power_supply/battery/capacity
uv_capacity_unbound || _status=1
if [ -f "$BK/orig_state" ]; then
    case "$(cat "$BK/orig_state" 2>/dev/null)" in
        existed)
            if [ -f "$BK/devicepolicy_orig.xml" ]; then
                cp -f "$BK/devicepolicy_orig.xml" "$XML" || _status=1
                chown system:system "$XML" 2>/dev/null
                chmod 600 "$XML" 2>/dev/null
            else
                uv_log "设备策略备份缺失，保留当前文件"
                _status=1
            fi ;;
        absent) rm -f "$XML" || _status=1 ;;
        *) uv_log "设备策略原状态无效，保留当前文件"; _status=1 ;;
    esac
fi
# 早启动时服务可能尚不存在，文件恢复供它启动后加载。
su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1

if [ "$_verified" != 1 ] || [ "$_status" != 0 ]; then
    mkdir -p "$BK"
    touch "$BK/skip" "$BK/restore_pending"
    uv_log "卸载恢复未验证完成：保留 restore_pending、原值和策略备份供后续恢复"
    uv_log "KernelSU 仍会继续删除模块目录；退出码不具有阻止删除的作用"
    exit 1
fi
rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml"     "$BK/target_mv" "$BK/no_adsp_write" "$BK/no_real_soc" "$BK/adsp_state"     "$BK/restore_pending" || exit 1
uv_log "卸载清理完成；保留原值、skip、卸载验证记录和日志"
