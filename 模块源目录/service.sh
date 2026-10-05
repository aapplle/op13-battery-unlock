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
            echo "$_dt" > "$BK/adsp_orig.txt"
            klog "⚠️ 读到的电量计值 ${_v} mV <= FLOOR=${FLOOR_MV}，疑似已被本模块修改，已用 DT 值回填 ${_dt} mV"
        else
            klog "⚠️ 读到的电量计值 ${_v} mV <= FLOOR=${FLOOR_MV}，疑似已被本模块修改，【拒绝备份】（DT 查表失败）"
        fi
        return 1
    fi
    echo "$_v" > "$BK/adsp_orig.txt"
    klog "已备份电量计原始终止电压 = ${_v} mV"
    return 0
}

# 查询模块最后一次【成功写入】的电量计终止电压记录（$BK/adsp_state）。
# 用途：越狱/硬重启后 uv_dev 可能为 NULL（读不了 ADSP），此时若记录显示
#   已经是目标值，就无需回写（不做后台补写，只做状态判定）。
# 只在写入后【读回校验一致】时才记录；卸载时会清除，避免跨模块生命周期失效。
adsp_known() {
    _k=$(cat "$BK/adsp_state" 2>/dev/null | tr -d "[:space:]")
    case "$_k" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_k" = "$1" ] && return 0
    return 1
}

uv_log_sep "service.sh 开始（KSU_LATE_LOAD=$KSU_LATE_LOAD）"

# 兜底：扫描并清理【所有】其他 service.sh 进程（
# 管不了更早的遗留进程 —— 实测发现旧版本残留的僵尸进程会一直存活到 1 小时超时）。
# 只保留当前进程自己（$$）。
_me=$$
_n=0
for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    [ "$_pid" = "$_me" ] && continue
    case "$_pid" in ""|*[!0-9]*) continue ;; esac
    _c=$(cat "$_p/cmdline" 2>/dev/null | tr "\0" " ")
    case "$_c" in
        *uv2800/service.sh*)
            kill "$_pid" 2>/dev/null && _n=$((_n+1))
            ;;
    esac
done
[ "$_n" -gt 0 ] && klog "已清理 $_n 个遗留的 service.sh 进程（只保留当前 pid=$$）"

# late-load（越狱）模式下系统已完全启动，不需要等待；标准启动才需要
# 主动触发捕获通常 1 秒内就绪，这里只留 5 秒保险，不必长时间 sleep
if [ "$KSU_LATE_LOAD" = "1" ]; then
    klog "late-load 模式，跳过等待"
else
    sleep 5
fi

# --- 1) 兜底 insmod（post-fs-data 时 oplus_chg_v2 可能还没就绪）---
if ! lsmod | grep -q "^uv2800"; then
    insmod "$MODDIR/uv2800.ko" 2>/dev/null
    klog "service.sh 兜底 insmod rc=$?"
fi

mkdir -p "$BK"

# --- 1.5) ★ 统一退出「恢复模式」（放在分支之前，所有分支都被覆盖）-------
# 【为什么统一在这里】把 uv_bypass 置 1（放行所有 hook）之后，内核里【没有】
#   任何自动复位路径，只能由用户态显式写 resume。
#   只要漏掉一处，vbat_uv 就会停在驱动自己算出的值、不跟随 uv_target_mv。
#   所以在这里复位一次，任何分支（含 no_adsp_write / skip / 解耦）都覆盖，
#   不必逐个分支各补一次。
#   （③④ hook 同属 uv_bypass 管辖，一并被放行/恢复。）
# 【实测依据】hook 生效（resume=0）时 vbat_uv 就是 uv_target_mv 的【即时镜像】：
#   改 uv_target_mv=3000/3100/3250，vbat_uv 逐字跟随，零延迟、无需 vote。
#   vbat_uv 不跟随只有一个原因 —— hook 被旁路了，
#   不是"驱动缓存需要插拔才能刷新"。
if [ "$(cat "$P/resume" 2>/dev/null)" = "1" ]; then
    klog "检测到内核 hook 处于恢复模式（uv_bypass=1），写 resume=1 统一复位"
    echo 1 > "$P/resume" 2>/dev/null
    sleep 1
    klog "hook 已复位（resume=$(cat "$P/resume" 2>/dev/null)），vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)"
fi

# --- 1.6) ★ 自动捕获 uv_dev ----------------------------------------
# 【为什么】uv_dev 只能由 oplus_fg_get_deep_term_volt 入口捕获，而该函数
#   只在驱动 vote 时被调用 —— 所以还需要一条不依赖 vote 的捕获路径。
# 【实测】oplus_fg_set_batt_deep_dischg_count 入口的 x0 与 getter 需要的 device
#   【完全相同】，而写 deep_dischg_counts（同值即可）就能触发它。
#   所以这里主动触发一次，后续 adsp_read/adsp_write 立即可用。
#   失败也不影响：后续分支仍有兜底逻辑处理。
echo 1 > "$P/adsp_read" 2>/dev/null
_uvd=$(cat "$P/adsp_read" 2>/dev/null)
case "$_uvd" in ''|*[!0-9]*) _uvd=0 ;; esac
if [ "$_uvd" -le 2000 ] 2>/dev/null; then
    klog "uv_dev 未捕获，主动触发 deep_dischg 入口"
    uv_capture_dev
    sleep 1
    echo 1 > "$P/adsp_read" 2>/dev/null
    klog "触发后 adsp_read=$(cat "$P/adsp_read" 2>/dev/null)"
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



if [ -f "$BK/no_adsp_write" ]; then
    klog "检测到 no_adsp_write 标记，本次不写电量计终止电压（测试用）"
elif [ -f "$BK/skip" ]; then
    # skip 由 action.sh 回写原值后创建。若存在说明用户已手动恢复，
    # 本次开机/软重启【不再】重新施加解耦，否则会把用户的恢复覆盖回解耦目标。
    klog "检测到 skip 标记（已手动恢复原值），本次不施加解耦"
    # --- ★ skip 语义 = 完全恢复原厂，三件事都要做到
    # 【为什么不能用恢复模式代替】写 resume=0 是【进入】恢复模式，方向反了：
    #   它（uv_bypass=1）只能让 hook"不再污染"，无法修正已经被污染的值。
    # 【正确做法】hook 直接返回运行时参数 uv_target_mv：
    #   只要 hook 生效（uv_bypass=0），vbat_uv 就是它的【即时镜像】——
    #   不依赖任何 vote、不怕模块重载。
    # 【ADSP 也要一起恢复】否则"skip 存在但 ADSP 仍是解耦目标"仍不一致
    #   （手动 touch skip、或 rm skip 解耦后再 touch skip 都会留下解耦目标）。
    _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d "[:space:]")
    case "$_orig" in ""|*[!0-9]*) _orig="" ;; esac
    # adsp_orig.txt 缺失/无效/疑似污染时，回退到 DT 查表
    # 读取侧静态判据：<3000 视为污染（DT 表最低档 = 3000），走 DT 兜底
    if [ -z "$_orig" ] || [ "$_orig" -lt 3000 ] 2>/dev/null || [ "$_orig" -gt 5000 ] 2>/dev/null; then
        _orig=$(uv_dt_orig)
        if [ -n "$_orig" ]; then
            klog "adsp_orig.txt 不可用，已从 DT 表计算原值 = ${_orig} mV"
            echo "$_orig" > "$BK/adsp_orig.txt"
        fi
    fi
    if [ -n "$_orig" ] && [ "$_orig" -ge 3000 ] 2>/dev/null && [ "$_orig" -le 5000 ] 2>/dev/null; then
        # ① hook 强制值设为原厂（保证 vbat_uv 恒为原厂）。
        #    退出「恢复模式」已提到脚本开头统一处理（见 1.5 节），这里只设值。
        if [ "$(cat "$P/uv_target_mv" 2>/dev/null)" != "$_orig" ]; then
            echo "$_orig" > "$P/uv_target_mv" 2>/dev/null
            sleep 1
            klog "已把内核 hook 强制值设为原厂 ${_orig} mV，vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)"
        fi
        # ② ★ 同时把 ADSP 也恢复为原厂（skip 语义 = 完全恢复原厂）。
        #   只改 hook 不改 ADSP 会造成"skip 存在但 ADSP 仍是解耦目标"的不一致：
        #   手动 touch skip、或 rm skip 解耦后再 touch skip，都会留下解耦目标。
        #   写入后读回校验，一致才记录 adsp_state（供 uv_dev 未捕获时判定）。
        _cur=$(echo 1 > "$P/adsp_read" 2>/dev/null; cat "$P/adsp_read" 2>/dev/null)
        if [ -n "$_cur" ] && [ "$_cur" -gt 2000 ] 2>/dev/null; then
            # 无论是否需要回写，都先同步 uv_adsp_mv（消除状态不一致）
            echo "$_orig" > "$P/uv_adsp_mv" 2>/dev/null
            if [ "$_cur" != "$_orig" ]; then
                echo "$_orig" > "$P/adsp_write" 2>/dev/null
                _rb=$(echo 1 > "$P/adsp_read" 2>/dev/null; cat "$P/adsp_read" 2>/dev/null)
                klog "已把 ADSP 恢复为原厂 ${_orig} mV（原 ${_cur}，读回 ${_rb}）"
                [ "$_rb" = "$_orig" ] && echo "$_orig" > "$BK/adsp_state" 2>/dev/null
            else
                klog "ADSP 已是原厂 ${_orig} mV，无需恢复"
                echo "$_orig" > "$BK/adsp_state" 2>/dev/null
            fi
        else
            # ③ ★ uv_dev 未捕获时，若记录显示已是原厂就跳过恢复。
            #    不做后台补写：主动触发后通常 1 秒即就绪，前面的探测循环
            #    已相当于同步重试，此处只做状态判定，不另起兜底进程。
            if adsp_known "$_orig"; then
                klog "uv_dev 未捕获，但 adsp_state 记录显示 ADSP 已是原厂 ${_orig} mV，无需恢复"
            else
                klog "⚠️ ADSP 未就绪（uv_dev 未捕获），本次无法恢复原厂 ${_orig} mV"
            fi
        fi
    else
        klog "⚠️ adsp_orig.txt 不可用（无原值记录），无法设置原厂强制值"
    fi
    klog "若要重新自动解耦，请执行：rm $BK/skip 后重启"
elif [ -w "$P/adsp_read" ]; then
    # --- ★ 把 hook 强制值设为用户自定义的 V_s -------------------------
    # 若上一轮处于 skip（已恢复原厂）模式，uv_target_mv 被设成了原厂值；
    # 这里（解耦模式）必须复位回 V_s，否则 hook 会继续强制原厂值，解耦失效。
    if [ "$(cat "$P/uv_target_mv" 2>/dev/null)" != "$V_S" ]; then
        echo "$V_S" > "$P/uv_target_mv" 2>/dev/null
        klog "已把内核 hook 强制值设为 ${V_S} mV（解耦模式）"
    fi
    # 无条件同步 uv_adsp_mv（③④ hook 的目标），防止残留默认值/上轮值
    echo "$ADSP_TARGET" > "$P/uv_adsp_mv" 2>/dev/null

    # 退出「恢复模式」已提到脚本开头统一处理（见 1.5 节）。

    # 探测 uv_dev 是否就绪。主动触发捕获后通常 0-1 秒就绪，10 秒足够。
    i=0; cur=""; _probe=ok
    while [ $i -lt 10 ]; do
        # 用户点「执行」后会出现 skip 标记，立刻停手，不要覆盖用户的恢复
        if [ -f "$BK/skip" ]; then
            klog "检测到 skip 标记（用户已手动恢复），停止解耦探测"
            _probe=skip
            break
        fi
        echo 1 > "$P/adsp_read" 2>/dev/null
        cur=$(cat "$P/adsp_read" 2>/dev/null)
        [ -n "$cur" ] && [ "$cur" -gt 2000 ] 2>/dev/null && break
        cur=""
        sleep 1
        i=$((i+1))
    done

    # 内核侧 adsp_read 默认静默（见 adsp_debug 参数），改由这里汇总一条。
    # 既保留「就绪耗时」这个真正有用的指标，又消掉每次开机最多 10 行（探测循环 10 次）的 dmesg 噪音。
    if [ "$_probe" = "ok" ]; then
        if [ -n "$cur" ]; then
            klog "ADSP 探测：${i}s 后就绪（终止电压 ${cur} mV）"
        else
            klog "⚠️ ADSP 探测：等待 ${i}s 未就绪（uv_dev 未捕获），本次放弃写入，将在下次开机重试"
        fi
    fi

    # skip 出现后不再写入（防止覆盖用户刚恢复的原值）
    [ -f "$BK/skip" ] && cur=""

    if [ -n "$cur" ]; then
        # ① uv_dev 就绪：主动写入（写后读回校验，一致才记录 adsp_state）
        if [ "$cur" != "$ADSP_TARGET" ]; then
            backup_orig "$cur"
            # 先同步 uv_adsp_mv（③④ hook 的目标），再写 ADSP
            echo "$ADSP_TARGET" > "$P/uv_adsp_mv" 2>/dev/null
            echo "$ADSP_TARGET" > "$P/adsp_write"
            _rb=$(echo 1 > "$P/adsp_read" 2>/dev/null; cat "$P/adsp_read" 2>/dev/null)
            klog "电量计终止电压 ${cur} -> ${ADSP_TARGET} mV（读回 ${_rb}，满电状态切换后重算 fcc）"
            [ "$_rb" = "$ADSP_TARGET" ] && echo "$ADSP_TARGET" > "$BK/adsp_state" 2>/dev/null
        else
            klog "电量计终止电压已是 ${ADSP_TARGET} mV，无需写入"
            echo "$ADSP_TARGET" > "$BK/adsp_state" 2>/dev/null
            # ADSP 已是目标值时，若 adsp_orig.txt 缺失也用 DT 回填
            if [ ! -f "$BK/adsp_orig.txt" ]; then
                _dt=$(uv_dt_orig 2>/dev/null)
                [ -n "$_dt" ] && echo "$_dt" > "$BK/adsp_orig.txt"
            fi
        fi
    else
        # ② uv_dev 未就绪：前面已用自动捕获尝试过（写 deep_dischg_counts 同值）。
        #    不做后台补写 —— 驱动不支持该入口时，本次开机即放弃写入，
        #    由下次开机重试（实测正常驱动 1 秒内就绪）。
        if adsp_known "$ADSP_TARGET"; then
            klog "uv_dev 未捕获，但 adsp_state 记录显示 ADSP 已是 ${ADSP_TARGET} mV，无需写入"
        else
            klog "⚠️ 读不到电量计终止电压（uv_dev 未就绪），本次无法写入 ${ADSP_TARGET} mV"
        fi
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
                cp -f "$BK/devicepolicy_orig.xml" "$XML"
                chown system:system "$XML" 2>/dev/null
                chmod 600 "$XML" 2>/dev/null
            else
                # 原文件存在但备份丢失 → 不动文件，报警
                klog "⚠️ 设备策略备份丢失（orig_state=existed 但 devicepolicy_orig.xml 不存在），保留当前文件"
            fi
        else
            rm -f "$XML"
        fi
    fi
    su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1
    rm -f "$BK/applied"
    klog "检测到 skip 标记（已手动恢复），已恢复设备策略"
    klog "若要重新自动应用，请 rm $BK/skip"
else
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

    i=0; ok=0
    while [ $i -lt 60 ]; do
        OUT=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1)
        case "$OUT" in
            *Parcel*) ok=1; break ;;
            *"Transaction too large"*)
                klog "⚠️ oplusdevicepolicy 出现 Transaction too large（/data/system 下策略 XML 堆积）"
                klog "   请将本日志反馈作者；本次跳过设备策略，不影响其他功能"
                ok=-1; break ;;
        esac
        sleep 1
        i=$((i+1))
    done
    if [ "$ok" = "1" ]; then
        su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 true i32 1" >/dev/null 2>&1
        klog "设备策略 $KEY=true（waited ${i}s）"
    elif [ "$ok" = "0" ]; then
        klog "⚠️ 等待 oplusdevicepolicy 服务超时（60s），设备策略未应用（下次开机重试）"
    fi
fi
