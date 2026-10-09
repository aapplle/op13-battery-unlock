#!/system/bin/sh
# 只读检查；没有采样或负载副作用。
# 【v10.8 研究存档】本文件 source 的 restore-target.sh 与 parameters/restore
# 检查属于 v10.8 布局；v11 模块（restore.sh + resume 参数）上会失败，
# 复测前须移植到 v11 接口。其余供电判据逻辑与版本无关。
study_power_is_discharge() {
    [ "$1" = 0 ] && [ "$2" = 0 ] && [ "$3" = 0 ] || return 1
    case "$4" in Discharging|'Not charging'|Full) ;; *) return 1 ;; esac
    case "$5" in ''|*[!0-9]*) return 1 ;; esac
    [ "$5" -gt 0 ]
}

study_preflight() {
    local mode target displayed usb wireless status soc content wired current chip_soc
    mode=${1:-smoke}
    case "$mode" in smoke|diagnostic|baseline) ;; *) return 1 ;; esac
    [ "$(id -u)" = 0 ] || { echo "需要 Root 读取完整测量节点" >&2; return 1; }
    [ -f /data/adb/modules/uv2800/disable ] || {
        echo "uv2800 未禁用；停止原厂基线准备" >&2; return 1;
    }
    if [ -d /data/adb/modules_update/uv2800 ]; then
        [ -f /data/adb/modules_update/uv2800/disable ] || {
            echo "待安装模块未禁用" >&2; return 1;
        }
    fi
    . /data/adb/modules/uv2800/restore-target.sh || return 1
    target=$(uv_restore_target) || return 1
    displayed=$(cat /sys/class/oplus_chg/battery/vbat_uv) || return 1
    [ "$displayed" = "$target" ] || {
        echo "vbat_uv=$displayed，原厂目标=$target；先核查恢复状态" >&2; return 1;
    }
    if [ -d /sys/module/uv2800 ]; then
        [ "$(cat /sys/module/uv2800/parameters/restore)" = "$target" ] || {
            echo "内存模块的恢复状态未确认" >&2; return 1;
        }
        [ -f /data/adb/uv2800_backup/skip ] || return 1
    fi
    if grep -q '/chip_soc .*capacity ' /proc/1/mountinfo; then
        echo "仍存在电量显示绑定" >&2; return 1
    fi
    [ -r /sys/class/oplus_chg/battery/battery_log_content ] || return 1
    if [ "$mode" != smoke ]; then
        [ -w /sys/power/wake_lock ] && [ -w /sys/power/wake_unlock ] || {
            echo "缺少可用的临时唤醒锁接口，无法保证熄屏后连续采样" >&2; return 1;
        }
        usb=$(cat /sys/class/power_supply/usb/online) || return 1
        wireless=$(cat /sys/class/power_supply/wireless/online) || return 1
        status=$(cat /sys/class/power_supply/battery/status) || return 1
        soc=$(cat /sys/class/power_supply/battery/capacity) || return 1
        content=$(cat /sys/class/oplus_chg/battery/battery_log_content) || return 1
        wired=$(printf '%s\n' "$content" | cut -d, -f9)
        current=$(printf '%s\n' "$content" | cut -d, -f6)
        chip_soc=$(printf '%s\n' "$content" | cut -d, -f7)
        study_power_is_discharge "$usb" "$wireless" "$wired" "$status" "$current" || {
            echo "等待无外部供电且电流放电：usb=$usb wireless=$wireless wired=$wired status=$status ibat_ma=$current" >&2
            return 1
        }
        if [ "$mode" = baseline ]; then
            [ "$soc" = 100 ] && [ "$chip_soc" = 100 ] || {
                echo "完整基线需 UI/电量计均为100%：ui=$soc chip=$chip_soc" >&2; return 1;
            }
        fi
    fi
    echo "原厂状态检查通过：目标 ${target}mV，mode=$mode" >&2
}

if [ "${0##*/}" = preflight.sh ]; then
    study_preflight "${1:-smoke}"
fi
