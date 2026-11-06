#!/system/bin/sh
# 模块卸载脚本：
#   1. 若内核模块仍在内存，将 hook 强制值设为原厂值并保持加载（避免 rmmod 重置 vbat_uv）
#   2. 解绑真实电量挂载，恢复设备策略原文件
#   3. 清理运行时状态标记，保留原值记录（adsp_orig.txt）、skip 标记与日志文件

MODDIR=${0%/*}
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_log_sep "uninstall.sh 卸载 开始"

BK=/data/adb/uv2800_backup
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

echo "- uv2800 卸载"

P=/sys/module/uv2800/parameters
if [ -d "$P" ]; then
    _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d "[:space:]")
    case "$_orig" in ''|*[!0-9]*) _orig="" ;; esac
    if [ -z "$_orig" ] || [ "$_orig" -lt 3000 ] 2>/dev/null || [ "$_orig" -gt 5000 ] 2>/dev/null; then
        _orig=$(uv_dt_orig 2>/dev/null)
    fi
    if [ -n "$_orig" ] && [ "$_orig" -ge 3000 ] 2>/dev/null; then
        echo "$_orig" > "$P/uv_shutdown_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_target_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_term_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_adsp_mv" 2>/dev/null
        echo 1 > "$P/resume" 2>/dev/null
        sleep 1
        echo "- 已把 hook 强制值设为原厂 ${_orig} mV（vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)）"
        uv_log "卸载前 hook 强制值设为原厂 ${_orig} mV"
    fi
fi

touch "$MODDIR/disable"
echo "- 模块已标记为禁用（hook 保持生效，vbat_uv 维持原厂值直到下次重启）"
uv_log "模块已禁用（未 rmmod，hook 保持生效）"

CAP=/sys/class/power_supply/battery/capacity
uv_unbind_capacity "$CAP"
_un=$?
if [ "$_un" -gt 0 ]; then
    echo "- 已恢复官方平滑电量显示（解绑 $_un 层）"
    uv_log "已恢复官方平滑电量显示（解绑 $_un 层）"
else
    echo "- 电量显示本来就是官方平滑值，无需恢复"
fi

if [ -f "$BK/orig_state" ]; then
    if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ]; then
        if [ -f "$BK/devicepolicy_orig.xml" ]; then
            cp -f "$BK/devicepolicy_orig.xml" "$XML"
            chown system:system "$XML" 2>/dev/null
            chmod 600 "$XML" 2>/dev/null
            echo "- 已恢复设备策略原文件（重启后超级省电功能恢复）"
        else
            echo "- ⚠️ 设备策略备份丢失（orig_state=existed 但 devicepolicy_orig.xml 不存在），保留当前文件"
            uv_log "⚠️ 设备策略备份丢失，保留当前文件"
        fi
    else
        rm -f "$XML"
        echo "- 原文件本不存在，已删除设备策略文件"
    fi
else
    echo "- 未找到设备策略备份，跳过恢复"
fi

su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1

if [ -f "$BK/adsp_orig.txt" ]; then
    echo "- ⚠️ 电量计终止电压可能仍不是原值（本脚本无法回写 ADSP）"
    echo "-    原值记录保留在 $BK/adsp_orig.txt = $(cat "$BK/adsp_orig.txt") mV"
fi
rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml"
rm -f "$BK/target_mv" "$BK/no_adsp_write" "$BK/no_real_soc" "$BK/no_policy" 2>/dev/null
rm -f "$BK/adsp_state" "$BK/.fcc_raw" 2>/dev/null

if [ -f "$BK/skip" ]; then
    echo "- 检测到 skip 标记（已恢复原厂），已保留 —— 重装后将保持原厂状态"
    echo "-       若要重新解耦，请执行：rm $BK/skip 后重启"
else
    echo "- 提示：重新安装本模块时会按默认流程重新解耦并应用设备策略"
fi
uv_log "卸载完成（日志保留在 $BK/uv2800.log）"
echo "- 完成"
