#!/system/bin/sh
# 服务阶段主脚本（标准启动与 late-load 模式共用，支持幂等重入）：
#   1. 兜底检查并加载 uv2800.ko
#   2. 捕获电量计 device 指针，按当前模式设置关机电压与 ADSP 终止电压
#   3. 重放 votable override
#   4. 按用户偏好同步真实电量绑定与超级省电设备策略
MODDIR=${0%/*}

P=/sys/module/uv2800/parameters
BK=/data/adb/uv2800_backup
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode
TARGET_MV_DEFAULT=2800
FLOOR_MV=3060
CS=/sys/class/oplus_chg/battery/chip_soc
CAP=/sys/class/power_supply/battery/capacity
CAPUE=/sys/class/power_supply/battery/uevent

[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
klog() { uv_log "$@"; }

# 备份电量计原厂终止电压：
# 原厂终止电压高于 FLOOR_MV（3060mV）；若读出值 <= 3060mV，说明 ADSP 已被修改，
# 拒绝将其作为原厂值备份，改为从设备树（DT）计算回填。
backup_orig() {
    _v="$1"
    if [ -f "$BK/adsp_orig.txt" ]; then
        return 0
    fi
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$_v" -le "$FLOOR_MV" ] 2>/dev/null; then
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

command -v adsp_known >/dev/null 2>&1 || adsp_known() { return 1; }

uv_log_sep "service.sh 开始（KSU_LATE_LOAD=$KSU_LATE_LOAD）"

# 清理可能残留的旧 service.sh 进程，仅保留当前进程
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

if [ "$KSU_LATE_LOAD" = "1" ]; then
    klog "late-load 模式，跳过等待"
else
    sleep 5
fi

# 1. 兜底加载内核模块
if ! lsmod | grep -q "^uv2800"; then
    insmod "$MODDIR/uv2800.ko" 2>/dev/null
    klog "service.sh 兜底 insmod rc=$?"
fi

mkdir -p "$BK"

# 触发内核重放 votable override，等待全部 votable 就绪
apply_votables() {
    _avi=0
    while [ "$_avi" -lt 10 ]; do
        echo 1 > "$P/uv_apply" 2>/dev/null
        [ "$(cat "$P/uv_apply" 2>/dev/null)" = "1" ] && {
            klog "votable override 已就绪（V_s=$(cat "$P/uv_target_mv" 2>/dev/null) mV）"
            return 0
        }
        _avi=$((_avi + 1))
        sleep 1
    done
    klog "⚠️ votable override 未就绪（uv_apply=$(cat "$P/uv_apply" 2>/dev/null)），请查看 dmesg"
    return 1
}

# 若内核 hook 处于旁路状态（resume=1），统一复位使 hook 重新生效
if [ "$(cat "$P/resume" 2>/dev/null)" = "1" ]; then
    klog "检测到内核 hook 处于恢复模式（uv_bypass=1），写 resume=1 统一复位"
    echo 1 > "$P/resume" 2>/dev/null
    sleep 1
    klog "hook 已复位（resume=$(cat "$P/resume" 2>/dev/null)），vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)"
fi

# 检查 uv_dev 是否已捕获，未捕获时通过 deep_dischg_counts 主动触发一次
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

# 读取并校验关机电压目标值 V_s（2800~3060mV），并计算对应的学习终止电压 T
if [ ! -f "$BK/target_mv" ]; then
    echo "$TARGET_MV_DEFAULT" > "$BK/target_mv"
    klog "已生成 $BK/target_mv = $TARGET_MV_DEFAULT（关机电压，可调 2800~3060）"
fi
V_S=$(cat "$BK/target_mv" 2>/dev/null | tr -d "[:space:]")
case "$V_S" in
    ''|*[!0-9]*) V_S=$TARGET_MV_DEFAULT ;;
esac
if [ "$V_S" -lt 2800 ] 2>/dev/null || [ "$V_S" -gt 3060 ] 2>/dev/null; then
    klog "⚠️ target_mv=$V_S 超出范围 2800~3060，回退默认值 $TARGET_MV_DEFAULT"
    V_S=$TARGET_MV_DEFAULT
    echo "$V_S" > "$BK/target_mv"
fi
TERM_TARGET=$((2 * V_S - 3060))
[ "$TERM_TARGET" -lt 2000 ] 2>/dev/null && TERM_TARGET=2000
[ "$TERM_TARGET" -gt 5000 ] 2>/dev/null && TERM_TARGET=5000
ADSP_TARGET=$TERM_TARGET
klog "关机电压 V_s=${V_S} mV，QBG 学习 term=${ADSP_TARGET} mV（公式派生）"

# 2. 按模式设置内核参数并写入 ADSP 终止电压
if [ -f "$BK/no_adsp_write" ]; then
    klog "检测到 no_adsp_write 标记，本次不写电量计终止电压（测试用）"
elif [ -f "$BK/skip" ]; then
    # skip 存在表示处于原厂恢复模式：将内核参数与 ADSP 终止电压均保持为原厂值
    klog "检测到 skip 标记（已手动恢复原值），本次不施加解耦"
    _orig=$(cat "$BK/adsp_orig.txt" 2>/dev/null | tr -d "[:space:]")
    case "$_orig" in ""|*[!0-9]*) _orig="" ;; esac
    # 读取侧判据：低于设备树最低档（3000mV）视为异常，退回设备树查表重算
    if [ -z "$_orig" ] || [ "$_orig" -lt 3000 ] 2>/dev/null || [ "$_orig" -gt 5000 ] 2>/dev/null; then
        _orig=$(uv_dt_orig)
        if [ -n "$_orig" ]; then
            klog "adsp_orig.txt 不可用，已从 DT 表计算原值 = ${_orig} mV"
            echo "$_orig" > "$BK/adsp_orig.txt"
        fi
    fi
    if [ -n "$_orig" ] && [ "$_orig" -ge 3000 ] 2>/dev/null && [ "$_orig" -le 5000 ] 2>/dev/null; then
        if [ "$(cat "$P/uv_shutdown_mv" 2>/dev/null)" != "$_orig" ]; then
            echo "$_orig" > "$P/uv_shutdown_mv" 2>/dev/null
            echo "$_orig" > "$P/uv_target_mv" 2>/dev/null
            echo "$_orig" > "$P/uv_term_mv" 2>/dev/null
            echo "$_orig" > "$P/uv_adsp_mv" 2>/dev/null
            sleep 1
            klog "已把内核 hook 强制值设为原厂 ${_orig} mV，vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null)"
        fi
        _cur=$(echo 1 > "$P/adsp_read" 2>/dev/null; cat "$P/adsp_read" 2>/dev/null)
        if [ -n "$_cur" ] && [ "$_cur" -gt 2000 ] 2>/dev/null; then
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
    # 解耦模式：更新关机电压与学习终止电压参数，并将终止电压写入 ADSP
    if [ "$(cat "$P/uv_shutdown_mv" 2>/dev/null)" != "$V_S" ]; then
        echo "$V_S" > "$P/uv_shutdown_mv" 2>/dev/null
        echo "$V_S" > "$P/uv_target_mv" 2>/dev/null
        klog "已把 shutdown hook 强制值设为 ${V_S} mV（解耦模式）"
    fi
    echo "$ADSP_TARGET" > "$P/uv_term_mv" 2>/dev/null
    echo "$ADSP_TARGET" > "$P/uv_adsp_mv" 2>/dev/null

    # 轮询等待 uv_dev 就绪（最长 10 秒），期间若出现 skip 标记则立即中止
    i=0; cur=""; _probe=ok
    while [ $i -lt 10 ]; do
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

    if [ "$_probe" = "ok" ]; then
        if [ -n "$cur" ]; then
            klog "ADSP 探测：${i}s 后就绪（终止电压 ${cur} mV）"
        else
            klog "⚠️ ADSP 探测：等待 ${i}s 未就绪（uv_dev 未捕获），本次放弃写入，将在下次开机重试"
        fi
    fi

    [ -f "$BK/skip" ] && cur=""

    if [ -n "$cur" ]; then
        if [ "$cur" != "$ADSP_TARGET" ]; then
            backup_orig "$cur"
            echo "$ADSP_TARGET" > "$P/uv_term_mv" 2>/dev/null
            echo "$ADSP_TARGET" > "$P/uv_adsp_mv" 2>/dev/null
            echo "$ADSP_TARGET" > "$P/adsp_write"
            _rb=$(echo 1 > "$P/adsp_read" 2>/dev/null; cat "$P/adsp_read" 2>/dev/null)
            klog "电量计终止电压 ${cur} -> ${ADSP_TARGET} mV（读回 ${_rb}，满电状态切换后重算 fcc）"
            [ "$_rb" = "$ADSP_TARGET" ] && echo "$ADSP_TARGET" > "$BK/adsp_state" 2>/dev/null
        else
            klog "电量计终止电压已是 ${ADSP_TARGET} mV，无需写入"
            echo "$ADSP_TARGET" > "$BK/adsp_state" 2>/dev/null
            if [ ! -f "$BK/adsp_orig.txt" ]; then
                _dt=$(uv_dt_orig 2>/dev/null)
                [ -n "$_dt" ] && echo "$_dt" > "$BK/adsp_orig.txt"
            fi
        fi
    else
        if adsp_known "$ADSP_TARGET"; then
            klog "uv_dev 未捕获，但 adsp_state 记录显示 ADSP 已是 ${ADSP_TARGET} mV，无需写入"
        else
            klog "⚠️ 读不到电量计终止电压（uv_dev 未就绪），本次无法写入 ${ADSP_TARGET} mV"
        fi
    fi
fi

apply_votables

# 3. 同步用户可选功能（真实电量显示 / 禁止 1% 超级省电）
if [ -f "$MODDIR/lib/features.sh" ]; then
    . "$MODDIR/lib/features.sh"
fi
if command -v feature_real_soc_sync >/dev/null 2>&1; then
    feature_real_soc_sync
    feature_policy_sync
else
    klog "缺少 lib/features.sh，跳过真实电量/策略（ADSP 不受影响）"
fi
