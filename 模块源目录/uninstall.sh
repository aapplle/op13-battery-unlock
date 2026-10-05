#!/system/bin/sh
# ============================================================
# uv2800 - 卸载脚本
#   KernelSU 在【下次开机】的早期阶段执行本脚本（那时模块已不在内存）
#
#   1) 把 hook 强制值设为原厂值，标记为禁用（不 rmmod）
#   2) 恢复「禁止超级省电」设备策略的原文件（纯文件，可以自动恢复）
#
# ⚠️ 电量计终止电压【无法】在这里恢复：
#    回写 ADSP 需要内核模块（oplus_fg_set_deep_term_volt），
#    而本脚本执行时模块已不在内存。
#    → 卸载前请先点模块的「操作」按钮（action.sh 会自动读实时 DT 算出原值回写）。
# ============================================================

MODDIR=${0%/*}
# 日志函数（stdout + dmesg + 落盘到备份目录），见 log.sh
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_log_sep "uninstall.sh 卸载 开始"

BK=/data/adb/uv2800_backup
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

echo "- uv2800 卸载"

# 把 hook 强制值设为原厂值，然后【不 rmmod】而是用 disable 标记。
# 【为什么不 rmmod】vbat_uv 是驱动内部值（易失），rmmod 移除 hook 后
#   驱动立即把它重置为 DT uv_thr(2800)，且软重启后驱动重新初始化也不会
#   从 ADSP term 恢复（实测确认）。不 rmmod 则 hook 保持生效，
#   vbat_uv 恒为原厂值。下次开机时 KernelSU 看到 disable 标记不加载模块，
#   驱动重新初始化，vbat_uv 回到 DT 默认值 2800（这是原厂行为，
#   因为原厂驱动的 vbat_uv 本来就是由驱动自己管理的）。
P=/sys/module/uv2800/parameters
if [ -d "$P" ]; then
    _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d "[:space:]")
    case "$_orig" in ''|*[!0-9]*) _orig="" ;; esac
    # 读取侧静态判据：<3000 视为污染（DT 表最低档 = 3000），走 DT 兜底
    if [ -z "$_orig" ] || [ "$_orig" -lt 3000 ] 2>/dev/null || [ "$_orig" -gt 5000 ] 2>/dev/null; then
        _orig=$(uv_dt_orig 2>/dev/null)
    fi
    if [ -n "$_orig" ] && [ "$_orig" -ge 3000 ] 2>/dev/null; then
        echo "$_orig" > "$P/uv_target_mv" 2>/dev/null
        echo "$_orig" > "$P/uv_adsp_mv" 2>/dev/null
        echo 1 > "$P/resume" 2>/dev/null
        sleep 1
        echo "- 已把 hook 强制值设为原厂 ${_orig} mV（vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)）"
        uv_log "卸载前 hook 强制值设为原厂 ${_orig} mV"
    fi
fi

# 不 rmmod，用 disable 标记让 KernelSU 下次不加载
touch "$MODDIR/disable"
echo "- 模块已标记为禁用（hook 保持生效，vbat_uv 维持原厂值直到下次重启）"
uv_log "模块已禁用（未 rmmod，hook 保持生效）"

# --- 恢复官方平滑电量显示 ------------------------------------
# 【为什么需要】service.sh 把 chip_soc 绑定到 capacity；卸载时若不 umount，
# 绑定会一直留在内存里（直到下次重启），状态栏显示的是真实 SOC 而非官方平滑值。
#   由 log.sh 的 uv_unbind_capacity() 统一实现（循环解绑，保证【恰好零层】）。
# ⚠️ namespace 说明：越狱模式下 service.sh 用 `nsenter -t 1 -m` 在 PID 1 的全局
#    mount namespace 里绑定；本脚本由 ksud 在自己的命名空间执行，普通 umount
#    【够不到】那层绑定（实测：卸载后仍显示真实 SOC）。必须先 nsenter 进去解绑。
CAP=/sys/class/power_supply/battery/capacity
uv_unbind_capacity "$CAP"
_un=$?
if [ "$_un" -gt 0 ]; then
    echo "- 已恢复官方平滑电量显示（解绑 $_un 层）"
    uv_log "已恢复官方平滑电量显示（解绑 $_un 层）"
else
    echo "- 电量显示本来就是官方平滑值，无需恢复"
fi

# --- 恢复设备策略原文件 ---
# 本脚本在开机早期执行，此时 oplusdevicepolicy 服务尚未启动，
# 恢复文件后服务会直接加载到「未设置」的状态。
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

# 兜底：若服务已启动（手动执行本脚本的情况），再调一次 setter
su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1

# --- 保留 adsp_orig.txt（记录电量计原值，供重新安装或手动恢复参考）---
if [ -f "$BK/adsp_orig.txt" ]; then
    echo "- ⚠️ 电量计终止电压可能仍不是原值（本脚本无法回写 ADSP）"
    echo "-    原值记录保留在 $BK/adsp_orig.txt = $(cat "$BK/adsp_orig.txt") mV"
    rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml"
    rm -f "$BK/target_mv" "$BK/no_adsp_write" "$BK/no_real_soc" 2>/dev/null
    rm -f "$BK/adsp_state" 2>/dev/null   # 模块已卸载，写入记录不再可信
else
    # 保留日志文件（uv2800.log），只清理状态标记，便于用户反馈问题
    rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml"
    rm -f "$BK/target_mv" "$BK/no_adsp_write" "$BK/no_real_soc" 2>/dev/null
    rm -f "$BK/adsp_state" 2>/dev/null   # 模块已卸载，写入记录不再可信
fi

if [ -f "$BK/skip" ]; then
    echo "- 检测到 skip 标记（已恢复原厂），已保留 —— 重装后将保持原厂状态"
    echo "-       若要重新解耦，请执行：rm $BK/skip 后重启"
else
    echo "- 提示：重新安装本模块时会按默认流程重新解耦并应用设备策略"
fi
uv_log "卸载完成（日志保留在 $BK/uv2800.log）"
echo "- 完成"
