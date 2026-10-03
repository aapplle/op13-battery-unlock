#!/system/bin/sh
# ============================================================
# uv2800 - service.sh（服务阶段；标准启动与 late-load 越狱模式都会执行）
#   1) 兜底 insmod（late-load 下由 late-load.sh 加载，这里是双保险）
#   2) ★ 原生 SOC 校准：把电量计终止电压设为 ADSP_TARGET（默认 2800）
#   3) ★ 显示真实电量：bind-mount chip_soc -> capacity（去掉官方平滑滞后）
#   4) 禁止低电量强制进入超级省电（OPPO 设备策略，COS15/16/17 通用）
#
# 【本脚本完全幂等】软重启后若管理器重跑 ksud late-load，可安全重复执行。
# ============================================================
MODDIR=${0%/*}

P=/sys/module/uv2800/parameters
BK=/data/adb/uv2800_backup                     # 备份目录放在模块【外】，卸载后仍存在
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode
ADSP_TARGET_DEFAULT=2600
CS=/sys/class/oplus_chg/battery/chip_soc
CAP=/sys/class/power_supply/battery/capacity
CAPUE=/sys/class/power_supply/battery/uevent

# late-load（越狱）模式下系统已完全启动，不需要等待；标准启动才需要
if [ "$KSU_LATE_LOAD" = "1" ]; then
    echo "uv2800: late-load 模式，跳过 sleep 20"
else
    sleep 20
fi

# --- 1) 兜底 insmod（post-fs-data 时 oplus_chg_v2 可能还没就绪）---
if ! lsmod | grep -q "^uv2800"; then
    insmod "$MODDIR/uv2800.ko" 2>/dev/null
    echo "uv2800: service.sh 兜底 insmod rc=$?"
fi

mkdir -p "$BK"

# --- * 解耦：ADSP 终止电压目标（控制电量计模型下限）---------------------
# 默认 2600（解耦推荐值：模型下限压到 2600，让 0% 段覆盖到 2800 附近）。
# 首次安装时自动生成 $BK/adsp_target；用户可手改（如 2800 = 不解耦、3000 = 保守）。
# 这个值【只影响电量计模型】，不影响关机电压 ——
# 关机电压由内核 getter hook 固定为 2800，两者完全独立。
if [ ! -f "$BK/adsp_target" ]; then
    echo "$ADSP_TARGET_DEFAULT" > "$BK/adsp_target"
    echo "uv2800: 已生成 $BK/adsp_target = $ADSP_TARGET_DEFAULT（解耦目标，可手改）"
fi
ADSP_TARGET=$(cat "$BK/adsp_target" 2>/dev/null | tr -d "[:space:]")
case "$ADSP_TARGET" in
    ''|*[!0-9]*) ADSP_TARGET=$ADSP_TARGET_DEFAULT ;;
esac
case "$ADSP_TARGET" in
    2[0-9][0-9][0-9]|3[0-9][0-9][0-9]) ;;
    *) ADSP_TARGET=$ADSP_TARGET_DEFAULT ;;
esac

# --- 2) ★ 原生 SOC 校准：电量计终止电压 -> ADSP_TARGET（默认 2800） ---------------------
# 实测：写 2800 + 充满一次 -> fcc 4346→4878；写 2600 + 充满 -> fcc 4854→4988
#       于是 rm/fcc 原生覆盖 3250~2800mV 那 450mV（不需要任何显示层 hack）。
# ⚠️ 电量计【实时读取】该值，但 fcc 重算需要一次满电状态切换（充满/满电拔插充电器）。
# ⚠️ ADSP_TARGET 与关机电压（内核 hook 固定 2800）完全解耦。
# ⚠️ 只在值不同时才写（避免反复写硬件寄存器，保护其寿命）。
if [ -f "$BK/no_adsp_write" ]; then
    echo "uv2800: 检测到 no_adsp_write 标记，本次不写电量计终止电压（测试用）"
elif [ -w "$P/adsp_read" ]; then
    i=0; cur=""
    while [ $i -lt 60 ]; do
        echo 1 > "$P/adsp_read" 2>/dev/null
        cur=$(cat "$P/adsp_read" 2>/dev/null)
        [ -n "$cur" ] && [ "$cur" -gt 2000 ] 2>/dev/null && break
        cur=""
        sleep 1
        i=$((i+1))
    done

    if [ -n "$cur" ]; then
        if [ "$cur" != "$ADSP_TARGET" ]; then
            if [ ! -f "$BK/adsp_orig.txt" ]; then
                echo "$cur" > "$BK/adsp_orig.txt"
                echo "uv2800: 已备份电量计原始终止电压 = ${cur} mV"
            fi
            echo "$ADSP_TARGET" > "$P/adsp_write"
            echo "uv2800: 电量计终止电压 ${cur} -> ${ADSP_TARGET} mV（满电状态切换后重算 fcc）"
        else
            echo "uv2800: 电量计终止电压已是 ${ADSP_TARGET} mV，无需写入"
        fi
    else
        echo "uv2800: 读不到电量计终止电压（uv_dev 未就绪），跳过原生 SOC 校准"
    fi
fi

# --- 3) ★ 显示真实电量：bind-mount chip_soc -> capacity ---------------
# 官方 capacity 走的是 OPPO oplus_comm 那一层的平滑值，高负载持续放电时会
# 严重滞后（实测 13W 放电 22 分钟，真实 79% 而显示 91%，差 13 个点）。
# 把电量计真实 SOC 绑定到 capacity，让状态栏/框架都看到真实值。
# 可用 touch $BK/no_real_soc 关闭此功能。
#
# ⚠️ mount namespace 说明（v10 修复）：
#   标准启动时本脚本由 init 拉起，处于全局 mount namespace，bind 全局生效。
#   late-load（越狱）模式下 ksud 从提权进程的命名空间 fork，bind 可能只在该
#   命名空间内可见（状态栏看不到）。此时优先用 nsenter 切入 PID 1 的命名空间。
do_bind() {
    umount "$CAP" 2>/dev/null
    mount --bind "$CS" "$CAP" 2>/dev/null
}

# 幂等设计（v10）：无论之前 bind 过多少次，先全部 umount 干净，再重新 bind 一次。
# 这样无论脚本被执行多少遍，最终都【恰好一层】绑定，且不依赖 /proc/mounts 探测
# （bind-mount 的挂载点记录的是解析后的真实路径，不是 $CAP 本身，探测不可靠）。
unbind_all() {
    i=0
    while [ $i -lt 8 ]; do
        umount "$CAP" 2>/dev/null || break
        i=$((i+1))
    done
}

if [ -f "$BK/no_real_soc" ]; then
    echo "uv2800: 检测到 no_real_soc 标记，保留官方平滑电量"
elif [ -e "$CS" ] && [ -e "$CAP" ]; then
    unbind_all
    bound=0
    if [ "$KSU_LATE_LOAD" = "1" ] && command -v nsenter >/dev/null 2>&1; then
        # 越狱模式：优先在 PID 1（全局）命名空间里做 bind
        if nsenter -t 1 -m -- mount --bind "$CS" "$CAP" 2>/dev/null; then
            bound=1
            echo "uv2800: 已绑定 chip_soc -> capacity（nsenter -t 1 -m，全局命名空间）"
        fi
    fi
    if [ "$bound" = "0" ] && do_bind; then
        bound=1
        echo "uv2800: 已绑定 chip_soc -> capacity（当前命名空间）"
    fi
    if [ "$bound" = "1" ]; then
        # 需要一次 uevent 让 Android 框架重新读取，否则要等下次电量变化
        echo change > "$CAPUE" 2>/dev/null
    else
        echo "uv2800: bind mount 失败，保留官方平滑电量"
    fi
fi

# --- 4) 禁止低电量强制进入超级省电 ------------------------------------
# 原理：com.oplus.battery 的 Utils.isSuperPowerSaveDisabled() 读这个设备策略；
#       true 时低电量强制对话框不再弹出、设置入口隐藏。
# 服务端 checkPermission() 要求 appId==1000 -> 必须 su 1000。
if [ -f "$BK/skip" ]; then
    echo "uv2800: 检测到 skip 标记（已手动恢复），本次不应用设备策略"
    echo "uv2800: 若要重新自动应用，请 rm $BK/skip"
else
    if [ ! -f "$BK/applied" ]; then
        if [ -f "$XML" ]; then
            cp -f "$XML" "$BK/devicepolicy_orig.xml"
            echo "existed" > "$BK/orig_state"
        else
            echo "absent" > "$BK/orig_state"
        fi
        touch "$BK/applied"
        echo "uv2800: 已备份设备策略原文件（原状态: $(cat "$BK/orig_state")）"
    fi

    i=0; ok=0
    while [ $i -lt 60 ]; do
        OUT=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1)
        case "$OUT" in
            *Parcel*) ok=1; break ;;
            *"Transaction too large"*)
                echo "uv2800: ⚠️ oplusdevicepolicy 出现 Transaction too large（/data/system 下策略 XML 堆积）"
                echo "uv2800:    请将本日志反馈作者；本次跳过设备策略，不影响其他功能"
                ok=-1; break ;;
        esac
        sleep 1
        i=$((i+1))
    done
    if [ "$ok" = "1" ]; then
        su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 true i32 1" >/dev/null 2>&1
        echo "uv2800: 设备策略 $KEY=true（waited ${i}s）"
    elif [ "$ok" = "0" ]; then
        echo "uv2800: ⚠️ 等待 oplusdevicepolicy 服务超时（60s），设备策略未应用（下次开机重试）"
    fi
fi
