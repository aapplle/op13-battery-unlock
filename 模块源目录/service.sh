#!/system/bin/sh
# ============================================================
# uv2800 - service.sh（服务阶段；标准启动与 late-load 越狱模式都会执行）
#   1) 兜底 insmod（late-load 下由 late-load.sh 加载，这里是双保险）
#   2) ★ 原生 SOC 校准：把电量计终止电压设为 ADSP_TARGET（由关机电压 V_s 派生，默认 V_s=2800 -> ADSP=2540）
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
TARGET_MV_DEFAULT=2800
FLOOR_MV=3060
CS=/sys/class/oplus_chg/battery/chip_soc
CAP=/sys/class/power_supply/battery/capacity
CAPUE=/sys/class/power_supply/battery/uevent


# 日志函数（stdout + dmesg + 落盘到备份目录），见 log.sh
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_lock || exit 1
klog() { uv_log "$@"; }

# 原值备份统一入口
# 【为什么必须判据】曾实测到 adsp_orig.txt 被备份成 2600（解耦目标）/2800（hook 污染值），
# 导致 action.sh 回写把 2800 当"原值"写回（真原值 3250）—— 备份一旦被污染，
# 之后所有恢复路径都会跟着用错值。
# 【判据】原值必须大于 FLOOR(3060)：模块可写 ADSP 范围是 [2540, 3060]，
# 所以 _v <= 3060 说明 ADSP 可能被本模块（在任何 V_S 下）改写过，此时【拒绝备份】。
# 误拒安全（DT 兜底结果相同），误接受危险（固化错误值）。
backup_orig() {
    _v="$1"
    if [ -f "$BK/adsp_orig.txt" ]; then
        return 0
    fi
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$_v" -le "$FLOOR_MV" ] 2>/dev/null; then
        # 拒绝时用 DT 值回填，避免文件保持缺失
        _dt=$(uv_dt_orig 2>/dev/null)
        if [ -n "$_dt" ]; then
            echo "$_dt" > "$BK/adsp_orig.txt" || return 1
            klog "⚠️ 读到的电量计值 ${_v} mV <= FLOOR=${FLOOR_MV}，疑似已被本模块修改，已用 DT 值回填 ${_dt} mV"
            return 0
        else
            klog "⚠️ 读到的电量计值 ${_v} mV <= FLOOR=${FLOOR_MV}，疑似已被本模块修改，【拒绝备份】（DT 查表失败）"
        fi
        return 1
    fi
    echo "$_v" > "$BK/adsp_orig.txt" || return 1
    klog "已备份电量计原始终止电压 = ${_v} mV"
    return 0
}

uv_log_sep "service.sh 开始（KSU_LATE_LOAD=$KSU_LATE_LOAD）"

# flock 串行化本次完整操作；不再按进程名杀掉其它实例。

# late-load（越狱）模式下系统已完全启动，不需要等待；标准启动才需要
# 主动触发捕获通常 1 秒内就绪，这里只留 5 秒保险，不必长时间 sleep
if [ "$KSU_LATE_LOAD" = "1" ]; then
    klog "late-load 模式，跳过等待"
else
    sleep 5
fi

# --- 1) 兜底 insmod（post-fs-data 时 oplus_chg_v2 可能还没就绪）---
if ! lsmod | grep -q "^uv2800"; then
    if ! insmod "$MODDIR/uv2800.ko"; then
        klog "错误：内核模块加载失败，停止应用"
        exit 1
    fi
fi

mkdir -p "$BK" || exit 1
_status=0
_restore_verified=0

# --- 1.6) ★ 自动捕获 uv_dev ----------------------------------------
# 【为什么】uv_dev 只能由 oplus_fg_get_deep_term_volt 入口捕获，而该函数
#   只在驱动 vote 时被调用 —— 所以还需要一条不依赖 vote 的捕获路径。
# 【实测】oplus_fg_set_batt_deep_dischg_count 入口的 x0 与 getter 需要的 device
#   【完全相同】，而写 deep_dischg_counts（同值即可）就能触发它。
#   所以这里主动触发一次，后续 adsp_read/adsp_write 立即可用。
#   失败也不影响：后续分支仍有兜底逻辑处理。
_uvd=$(uv_read_adsp "$P") || _uvd=0
case "$_uvd" in ''|*[!0-9]*) _uvd=0 ;; esac
if [ "$_uvd" -le 2000 ] 2>/dev/null; then
    klog "uv_dev 未捕获，主动触发 deep_dischg 入口"
    uv_capture_dev
    sleep 1
    _uvd=$(uv_read_adsp "$P") || _uvd=0
    klog "触发后 adsp_read=$_uvd"
fi

# --- * 关机电压自定义 + ADSP 自动派生 -------------------------------
# 用户可调：关机电压 V_s（2800~3060，默认 2800），落盘 $BK/target_mv。
# ADSP 由 V_s 自动派生：偏移 = max(0, FLOOR - V_s)，term = V_s - 偏移。
# FLOOR=3060（新机原厂关机电压 = 电量计模型的计数下限）。
# 不再需要用户手改 ADSP 值。
if [ ! -f "$BK/target_mv" ]; then
    echo "$TARGET_MV_DEFAULT" > "$BK/target_mv"
    klog "已生成 $BK/target_mv = $TARGET_MV_DEFAULT（关机电压，可调 2800~3060）"
fi
V_S=$(cat "$BK/target_mv" 2>/dev/null | tr -d "[:space:]")
case "$V_S" in
    ''|*[!0-9]*) V_S=$TARGET_MV_DEFAULT ;;
esac
# 范围校验：2800~3060，越界则拒绝并回退默认值
if [ "$V_S" -lt 2800 ] 2>/dev/null || [ "$V_S" -gt 3060 ] 2>/dev/null; then
    klog "⚠️ target_mv=$V_S 超出范围 2800~3060，回退默认值 $TARGET_MV_DEFAULT"
    V_S=$TARGET_MV_DEFAULT
    echo "$V_S" > "$BK/target_mv"
fi
# 派生 ADSP 目标：偏移 = max(0, FLOOR - V_s)
_offset=$((FLOOR_MV - V_S))
[ "$_offset" -lt 0 ] && _offset=0
ADSP_TARGET=$((V_S - _offset))
klog "关机电压 V_s=${V_S} mV，ADSP 派生=${ADSP_TARGET} mV（偏移 ${_offset}，FLOOR=${FLOOR_MV}）"

# --- 2) ★ 原生 SOC 校准：解耦写入电量计终止电压（adsp_write 主动写）---------
# 【为什么必须主动写】解耦写入【唯一可靠路径】是模块主动 adsp_write：
#   驱动只在「vote 目标 != 当前 ADSP」时才调 setter 写 term，日常 vote 目标=3250
#   =ADSP 原值，值相同驱动不写 -> setter hook（④）日常不触发 -> 单靠被动拦截
#   无法把 ADSP 改成目标值。只有 adsp_write 主动调
#   oplus_fg_set_deep_term_volt(uv_dev, ADSP_TARGET) 才会真正写进 ADSP。
#   （④ 并非全程不触发：驱动定期把 ADSP 纠回它在 ③ 处读到的值时 ④ 会执行，
#    并把写入值统一成 uv_adsp_mv —— 见内核 uv_term_set 注释。）
# 【两种模式统一用 adsp_write】，区别只在 uv_dev 是否已捕获：
#   ① 标准模式：开机 vote 时 getter 已捕获 uv_dev -> 直接 adsp_write 写 ADSP_TARGET。
#   ② 越狱模式：开机 vote 已错过，uv_dev=NULL -> 由 kp_ddrc 补捕获。
# 电量计【实时读取】ADSP term，但 fcc 重算仍需一次满电状态切换。



if [ -f "$BK/skip" ]; then
    # skip 是恢复意图；restore_pending 存在表示本次尚未实时验证完成。
    touch "$BK/restore_pending" || exit 1
    rm -f "$BK/adsp_state" || exit 1
    _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d "[:space:]")
    case "$_orig" in ''|*[!0-9]*) _orig="" ;; esac
    if [ -z "$_orig" ] || [ "$_orig" -lt 3000 ] 2>/dev/null || [ "$_orig" -gt 5000 ] 2>/dev/null; then
        _orig=$(uv_dt_orig) || _orig=""
        if [ -n "$_orig" ]; then
            echo "$_orig" > "$BK/adsp_orig.txt" || exit 1
        fi
    fi
    if [ -n "$_orig" ] && uv_set_targets "$_orig" "$_orig" "$P"; then
        # 指针未捕获也必须先同步两个 hook，避免后续厂商 setter 继续写解耦值。
        _cur=$(uv_read_adsp "$P") || _cur=""
        if [ -n "$_cur" ]; then
            if [ "$_cur" != "$_orig" ] && ! echo "$_orig" > "$P/adsp_write"; then
                klog "错误：原厂 ADSP 回写失败，保留恢复待办"
                _status=1
            fi
            _rb=$(uv_read_adsp "$P") || _rb=""
            if [ "$_status" = 0 ] && [ "$_rb" = "$_orig" ]; then
                echo "$_orig" > "$BK/adsp_state" || exit 1
                _restore_verified=1
                klog "已实时验证 ADSP 恢复为原厂 ${_orig} mV"
            else
                klog "错误：原厂 ADSP 校验失败（读回 ${_rb:-未知}，目标 $_orig），保留恢复待办"
                _status=1
            fi
        else
            klog "错误：ADSP 读取失败，两个 hook 已设原厂值；保留恢复待办，下次启动重试"
            _status=1
        fi
    else
        klog "错误：原厂值计算或 hook 参数设置失败，保留恢复待办"
        _status=1
    fi
elif [ -f "$BK/no_adsp_write" ]; then
    klog "检测到 no_adsp_write 标记，本次不写电量计终止电压（测试用）"
else
    uv_set_targets "$V_S" "$ADSP_TARGET" "$P" || { klog "错误：设置解耦 hook 参数失败"; exit 1; }
    # 持锁期间 action 会等待；不再通过非原子的 skip 检查协调写入。
    i=0; cur=""
    while [ "$i" -lt 10 ]; do
        cur=$(uv_read_adsp "$P") && break
        cur=""
        sleep 1
        i=$((i+1))
    done
    rm -f "$BK/adsp_state" || exit 1
    if [ -n "$cur" ]; then
        if [ "$cur" != "$ADSP_TARGET" ]; then
            if ! backup_orig "$cur"; then
                klog "错误：原值备份失败，本次停止 ADSP 主动写入"
                _status=1
            elif ! echo "$ADSP_TARGET" > "$P/adsp_write"; then
                klog "错误：ADSP 解耦写入失败"
                _status=1
            fi
        elif [ ! -f "$BK/adsp_orig.txt" ]; then
            _dt=$(uv_dt_orig) || _dt=""
            [ -z "$_dt" ] || echo "$_dt" > "$BK/adsp_orig.txt"
        fi
        _rb=$(uv_read_adsp "$P") || _rb=""
        if [ "$_status" = 0 ] && [ "$_rb" = "$ADSP_TARGET" ]; then
            echo "$ADSP_TARGET" > "$BK/adsp_state" || exit 1
            klog "ADSP ${ADSP_TARGET} mV 已实时验证（就绪耗时 ${i}s）"
        else
            klog "错误：ADSP 校验失败（读回 ${_rb:-未知}，目标 $ADSP_TARGET）"
            _status=1
        fi
    else
        klog "错误：等待 ${i}s 仍未读到电量计，本次未确认 ADSP，下次启动重试"
        _status=1
    fi
fi
# --- 3) ★ 显示真实电量：bind-mount chip_soc -> capacity ---------------
# 官方 capacity 走的是 OPPO oplus_comm 那一层的平滑值，高负载持续放电时会
# 严重滞后（实测 13W 放电 22 分钟，真实 79% 而显示 91%，差 13 个点）。
# 把电量计真实 SOC 绑定到 capacity，让状态栏/框架都看到真实值。
# 可用 touch $BK/no_real_soc 关闭此功能。
#
# ⚠️ mount namespace 说明：
#   标准启动时本脚本由 init 拉起，处于全局 mount namespace，bind 全局生效。
#   late-load（越狱）模式下 ksud 从提权进程的命名空间 fork，bind 可能只在该
#   命名空间内可见（状态栏看不到）。此时优先用 nsenter 切入 PID 1 的命名空间。
do_bind() {
    umount "$CAP" 2>/dev/null
    mount --bind "$CS" "$CAP" 2>/dev/null
}

# 幂等设计：无论之前 bind 过多少次，先全部 umount 干净，再重新 bind 一次。
# 由 log.sh 的 uv_unbind_capacity() 统一实现（含 PID 1 全局命名空间）。

if [ -f "$BK/no_real_soc" ]; then
    # no_real_soc 语义 = 恢复官方平滑电量 —— 主动解绑，不仅"不绑定"。
    uv_unbind_capacity "$CAP" "$CAPUE"
    klog "检测到 no_real_soc 标记，已解绑真实电量显示"
elif [ -f "$BK/skip" ]; then
    # skip 语义 = 完全恢复原厂 —— 主动解绑 capacity，不仅"不绑定"。
    uv_unbind_capacity "$CAP" "$CAPUE"
    klog "检测到 skip 标记（已手动恢复），已解绑真实电量显示"
elif [ -e "$CS" ] && [ -e "$CAP" ]; then
    uv_unbind_capacity "$CAP" "$CAPUE"
    bound=0
    if [ "$KSU_LATE_LOAD" = "1" ] && command -v nsenter >/dev/null 2>&1; then
        # 越狱模式：优先在 PID 1（全局）命名空间里做 bind
        if nsenter -t 1 -m -- mount --bind "$CS" "$CAP" 2>/dev/null; then
            bound=1
            klog "已绑定 chip_soc -> capacity（nsenter -t 1 -m，全局命名空间）"
        fi
    fi
    if [ "$bound" = "0" ] && do_bind; then
        bound=1
        klog "已绑定 chip_soc -> capacity（当前命名空间）"
    fi
    if [ "$bound" = "1" ]; then
        # 需要一次 uevent 让 Android 框架重新读取，否则要等下次电量变化
        echo change > "$CAPUE" 2>/dev/null
    else
        klog "bind mount 失败，保留官方平滑电量"
    fi
fi

# --- 4) 禁止低电量强制进入超级省电 ------------------------------------
# 原理：com.oplus.battery 的 Utils.isSuperPowerSaveDisabled() 读这个设备策略；
#       true 时低电量强制对话框不再弹出、设置入口隐藏。
# 服务端 checkPermission() 要求 appId==1000 -> 必须 su 1000。
if [ -f "$BK/skip" ]; then
    # skip 语义 = 完全恢复原厂 —— 主动恢复设备策略，不仅"不应用"。
    # 手动 touch skip 或重装带旧 skip 时，action.sh 的策略恢复可能未执行，
    # 这里兜底确保策略被恢复。
    if [ -f "$BK/orig_state" ]; then
        if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ]; then
            if [ -f "$BK/devicepolicy_orig.xml" ]; then
                cp -f "$BK/devicepolicy_orig.xml" "$XML" || _status=1
                chown system:system "$XML" 2>/dev/null
                chmod 600 "$XML" 2>/dev/null
            else
                # 原文件存在但备份丢失 → 不动文件，报警
                klog "⚠️ 设备策略备份丢失（orig_state=existed 但 devicepolicy_orig.xml 不存在），保留当前文件"
                _status=1
            fi
        else
            rm -f "$XML" || _status=1
        fi
    fi
    su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1 || _status=1
    rm -f "$BK/applied"
    klog "检测到 skip 标记（已手动恢复），已恢复设备策略"
    klog "若要重新自动应用，请 rm $BK/skip"
else
    if [ ! -f "$BK/applied" ]; then
        if [ -f "$XML" ]; then
            cp -f "$XML" "$BK/devicepolicy_orig.xml" || exit 1
            echo "existed" > "$BK/orig_state"
        else
            echo "absent" > "$BK/orig_state"
        fi
        touch "$BK/applied"
        klog "已备份设备策略原文件（原状态: $(cat "$BK/orig_state")）"
    fi

    i=0; ok=0
    while [ $i -lt 60 ]; do
        OUT=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1)
        case "$OUT" in
            *Parcel*) ok=1; break ;;
            *"Transaction too large"*)
                klog "⚠️ oplusdevicepolicy 出现 Transaction too large（/data/system 下策略 XML 堆积）"
                klog "   请将本日志反馈作者；本次跳过设备策略，不影响其他功能"
                ok=-1; _status=1; break ;;
        esac
        sleep 1
        i=$((i+1))
    done
    if [ "$ok" = "1" ]; then
        su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 true i32 1" >/dev/null 2>&1 || _status=1
        klog "设备策略 $KEY=true（waited ${i}s）"
    elif [ "$ok" = "0" ]; then
        klog "⚠️ 等待 oplusdevicepolicy 服务超时（60s），设备策略未应用（下次开机重试）"
        _status=1
    fi
fi

if [ "$_restore_verified" = 1 ] && [ "$_status" = 0 ]; then
    rm -f "$BK/restore_pending" || exit 1
fi
exit "$_status"
