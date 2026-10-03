#!/system/bin/sh
# ============================================================
# uv2800 - 卸载脚本
#   KernelSU 在【下次开机】的早期阶段执行本脚本（那时模块已不在内存）
#
#   1) 卸载内核模块
#   2) 恢复「禁止超级省电」设备策略的原文件（纯文件，可以自动恢复）
#
# ⚠️ 电量计终止电压【无法】在这里恢复：
#    回写 ADSP 需要内核模块（oplus_fg_set_deep_term_volt），
#    而本脚本执行时模块已不在内存。
#    → 卸载前请先点模块的「操作」按钮（action.sh 会自动读实时 DT 算出原值回写）。
# ============================================================

MODDIR=${0%/*}
# v10.7：日志函数（stdout + dmesg + 落盘到备份目录），见 log.sh
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_log_sep "uninstall.sh 卸载 开始"

BK=/data/adb/uv2800_backup
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

echo "- uv2800 卸载"
rmmod uv2800 2>/dev/null

# --- 恢复官方平滑电量显示（v10.7）------------------------------------
# 【为什么需要】service.sh 把 chip_soc 绑定到 capacity；卸载时若不 umount，
# 绑定会一直留在内存里（直到下次重启），状态栏显示的是真实 SOC 而非官方平滑值。
# 写法参考 service.sh 的 unbind_all()：循环解绑，保证【恰好零层】。
# ⚠️ namespace 说明：越狱模式下 service.sh 用 `nsenter -t 1 -m` 在 PID 1 的全局
#    mount namespace 里绑定；本脚本由 ksud 在自己的命名空间执行，普通 umount
#    【够不到】那层绑定（实测：卸载后仍显示真实 SOC）。必须先 nsenter 进去解绑。
CAP=/sys/class/power_supply/battery/capacity
_un=0
if command -v nsenter >/dev/null 2>&1; then
    while [ "$_un" -lt 8 ]; do
        nsenter -t 1 -m -- umount "$CAP" 2>/dev/null || break
        _un=$((_un+1))
    done
fi
# 兜底：本命名空间（标准启动模式下 service.sh 就是在本命名空间绑的）
while [ "$_un" -lt 8 ]; do
    umount "$CAP" 2>/dev/null || break
    _un=$((_un+1))
done
if [ "$_un" -gt 0 ]; then
    echo change > /sys/class/power_supply/battery/uevent 2>/dev/null
    echo "- 已恢复官方平滑电量显示（解绑 $_un 层）"
    uv_log "已恢复官方平滑电量显示（解绑 $_un 层）"
else
    echo "- 电量显示本来就是官方平滑值，无需恢复"
fi

# --- 恢复设备策略原文件 ---
# 本脚本在开机早期执行，此时 oplusdevicepolicy 服务尚未启动，
# 恢复文件后服务会直接加载到「未设置」的状态。
if [ -f "$BK/orig_state" ]; then
    if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ] && [ -f "$BK/devicepolicy_orig.xml" ]; then
        cp -f "$BK/devicepolicy_orig.xml" "$XML"
        chown system:system "$XML" 2>/dev/null
        chmod 600 "$XML" 2>/dev/null
        echo "- 已恢复设备策略原文件（重启后超级省电功能恢复）"
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
    rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml" "$BK/skip"
    rm -f "$BK/adsp_target" "$BK/no_adsp_write" "$BK/no_real_soc" "$BK/retry.pid" 2>/dev/null
else
    # v10.7：保留日志文件（uv2800.log），只清理状态标记，便于用户反馈问题
    rm -f "$BK/applied" "$BK/orig_state" "$BK/devicepolicy_orig.xml" "$BK/skip"
    rm -f "$BK/adsp_target" "$BK/no_adsp_write" "$BK/no_real_soc" "$BK/retry.pid" 2>/dev/null
fi

echo "- 提示：重新安装本模块时，「禁止超级省电」策略会自动应用；"
echo "-       若曾点过「操作」按钮且不想自动应用，保留 skip 标记即可"
uv_log "卸载完成（日志保留在 $BK/uv2800.log）"
echo "- 完成"
