#!/system/bin/sh
# ============================================================
# uv2800 - 操作按钮：把「原值」写回电量计 ADSP
#
# 【为什么需要这个按钮】
#   社区主流方案是修改 dtbo。刷回原版 dtbo 也【不能】恢复电量计里
#   已经被写入的终止电压，只能等它按约 20mV/次充放电慢慢恢复。
#   本按钮提供一个手动恢复手段。
#
# 【原值是怎么算出来的】
#   ① 优先用【首次写入前的备份】adsp_orig.txt（那是驱动自己算出来的值）；
#   ② 备份缺失/被判污染时，用 log.sh 的 uv_dt_orig() 按【厂商标准】重算：
#        ratio   = 10 × deep_dischg_counts / cc        (cc = battery_cc = 循环次数)
#        region  = ratio 与 oplus,ratio_range[20,30,50,70,90] 比较（≥ 抬档）
#        index_t = 温度与 oplus,temp_range[-50,100,350] 比较（≤ 归下档）
#        表      = <battery_type>/ddrc_strategy/strategy_ratio_range_<region>/strategy_temp_<温度>
#        行 k    = 最后一个满足 max(0, f0 − count_cali) ≤ cc 的行，取第 3 个字段（终止电压）
#   实测（ColorOS 16.0.5.701 / 内核 6.6.89，counts=1758 / cc=344 / 温度 normal）→ 3250，
#   与驱动 vterm_final 及开机写入值完全一致。C15/C17 仅完成静态核对，无真机数据。
#   ⚠️ 终止电压【不能】从 deep_spec,term_coeff 查：那张表只决定驱动"用哪张 ddrc 表"，
#      不是电压来源；选行输入也必须是 cc 而不是 raw counts（照抄它会算成 3350，与驱动不符）。
#   本脚本不依赖任何硬编码值，全部从实时 DT + sysfs 读取。
#
# 【试运行】
#   UV2800_DRYRUN=1 sh action.sh   # 只算不写，用于验证计算路径
# ============================================================

MODDIR=${0%/*}
# 日志函数（stdout + dmesg + 落盘到备份目录），见 log.sh
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }

uv_lock || exit 1
uv_log_sep "action.sh 恢复原值 开始"

PARAM=/sys/module/uv2800/parameters/adsp_write
VBAT=/sys/class/oplus_chg/battery/vbat_uv
VOLT_NOW=/sys/class/power_supply/battery/voltage_now
BK=/data/adb/uv2800_backup
P=${PARAM%/*}

restore_fail() {
    uv_log "恢复尚未完成：$*；保留 skip / restore_pending，请重试恢复后再卸载"
    exit 1
}

echo "=========================================="
echo "  uv2800  恢复原值（写回电量计 ADSP）"
[ "$UV2800_DRYRUN" = "1" ] && echo "  【试运行模式：只算不写】"
echo "=========================================="
echo ""

if [ ! -e "$PARAM" ]; then
    echo "✗ 找不到 $PARAM"
    echo "  说明模块没有加载。请检查："
    echo "  - /data/adb/modules/uv2800/disable 是否存在"
    echo "  - 或重启手机后再试"
    exit 1
fi

# --- 0) 低电压警告 -------------------------------------------------
# 实测依据（文档 §23.4.4）：若在电量计空电点附近（vbat < 回写目标）执行回写，
# vbat < term 会让电量计进入钳位态（DOD=100% 不自愈），需要充满一次才恢复。
# 注意：本机 voltage_now 是【单芯】电压（µV），不是双芯之和。
VN=$(cat "$VOLT_NOW" 2>/dev/null)
case "$VN" in ''|*[!0-9]*) VN=0 ;; esac
VN=$((VN / 1000))
if [ "$VN" -gt 0 ]; then
    echo "- 当前电池电压: ${VN} mV"
    if [ "$VN" -lt 3300 ]; then
        echo ""
        echo "  ⚠️⚠️ 电池电压偏低（< 3300mV）⚠️⚠️"
        echo "  建议先充电到 3250mV 以上再执行回写，"
        echo "  否则电量计可能进入钳位态（SOC 卡 0%，需充满一次才恢复）。"
        echo ""
    fi
fi

# --- 1) 计算原值：① 首次写入前的备份  ② 厂商标准重算（兜底）---------
# 【为什么优先用备份】service.sh 在【首次写入前】把电量计当时的真实值存进
# adsp_orig.txt，那个值就是驱动自己算出来的原值。
# 兜底路径由 log.sh 的 uv_dt_orig() 统一实现（复刻驱动 ddrc_strategy 两维查表）。
TARGET=""
ORIG="$BK/adsp_orig.txt"
if [ -f "$ORIG" ]; then
    T=$(cat "$ORIG" 2>/dev/null | tr -d "[:space:]")
    case "$T" in ''|*[!0-9]*) T="" ;; esac
    if [ -n "$T" ] && [ "$T" -lt 3000 ] 2>/dev/null; then
        # 读取侧静态判据：<3000 视为污染（DT 表最低档 = 3000），隔离并走厂商标准重算
        echo "- ⚠️ adsp_orig.txt=$T mV 疑似污染值（DT 表最低档 3000），改用厂商标准重算"
        uv_log "adsp_orig.txt=$T 疑似污染${UV2800_DRYRUN:+（试运行时保留备份）}"
        if [ "$UV2800_DRYRUN" != "1" ]; then
            mv -f "$ORIG" "$BK/adsp_orig.bad" || exit 1
        fi
        T=""
    fi
    if [ -n "$T" ] && [ "$T" -ge 3000 ] && [ "$T" -le 5000 ]; then
        TARGET="$T"
        echo "- 原值来源   : 首次写入前的备份 adsp_orig.txt"
    fi
fi

if [ -z "$TARGET" ]; then
    echo "- 原值来源   : 厂商标准重算（adsp_orig.txt 缺失或无效）"
    TARGET=$(uv_dt_orig)
fi

case "$TARGET" in ''|*[!0-9]*) TARGET=-1 ;; esac
if [ "$TARGET" -lt 2000 ] || [ "$TARGET" -gt 5000 ]; then
    echo "✗ 计算失败（得到 '$TARGET'）"
    echo "  请把以下信息反馈给作者："
    echo "    deep_dischg_counts = $(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_counts 2>/dev/null)"
    echo "    battery_cc         = $(cat /sys/class/oplus_chg/battery/battery_cc 2>/dev/null)"
    echo "    count_cali         = $(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali 2>/dev/null)"
    echo "    battery temp       = $(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
    echo "    （重跑时加 UV_DT_DEBUG=1 可打印完整推导过程）"
    echo "    adsp_orig.txt = $([ -f "$ORIG" ] && cat "$ORIG" || echo '不存在')"
    exit 1
fi
echo "- 算出的原值 : ${TARGET} mV"
echo ""

if [ "$UV2800_DRYRUN" = "1" ]; then
    echo "【试运行】目标值 ${TARGET} mV 计算完成，未写设备或修改原值备份。"
    exit 0
fi

# 恢复操作与 service / uninstall 共用锁。先记录意图，再改参数/硬件。
mkdir -p "$BK" && touch "$BK/skip" "$BK/restore_pending" || restore_fail "写入恢复标记失败"
rm -f "$BK/adsp_state" || restore_fail "清理旧写入记录失败"
if [ ! -f "$ORIG" ]; then
    echo "$TARGET" > "$ORIG" || restore_fail "保存原厂值失败"
fi

# 两个 hook 目标必须一起恢复，设备指针是否就绪不影响参数同步。
uv_set_targets "$TARGET" "$TARGET" "$P" || restore_fail "hook 参数设置或校验失败"
READY=$(uv_read_adsp "$P") || READY=""
if [ -z "$READY" ]; then
    echo "- 尝试捕获电量计设备指针..."
    uv_capture_dev
    sleep 1
    READY=$(uv_read_adsp "$P") || READY=""
fi
[ -n "$READY" ] || restore_fail "电量计读取失败（接口不可用、尚未捕获指针或驱动返回错误）"
if [ "$READY" != "$TARGET" ]; then
    echo "$TARGET" > "$PARAM" || restore_fail "电量计回写失败"
fi
# 即使第一次读取已相等，也进行最终实时读取；不采用持久缓存跳过验证。
_rb=$(uv_read_adsp "$P") || restore_fail "回写后读取失败"
[ "$_rb" = "$TARGET" ] || restore_fail "读回 ${_rb} mV 与目标 ${TARGET} mV 不一致"
echo "$TARGET" > "$BK/adsp_state" || restore_fail "保存验证结果失败"
CURV=$(cat "$VBAT" 2>/dev/null | tr -d "[:space:]")
[ "$CURV" = "$TARGET" ] || restore_fail "关机电压 ${CURV:-未知} mV 未跟随 ${TARGET} mV"
okv=skip
echo "- 已实时验证：ADSP / 关机电压均为 ${TARGET} mV"

# --- 5) 同时恢复「禁止超级省电」设备策略 ---------------------
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

echo ""
echo "- 恢复设备策略（超级省电）..."
su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1 || restore_fail "设备策略接口调用失败"
if [ -f "$BK/orig_state" ]; then
    if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ]; then
        if [ -f "$BK/devicepolicy_orig.xml" ]; then
            cp -f "$BK/devicepolicy_orig.xml" "$XML" || restore_fail "恢复设备策略备份失败"
            chown system:system "$XML" 2>/dev/null
            chmod 600 "$XML" 2>/dev/null
        else
            # 原文件存在但备份丢失 → 不动文件，报警
            echo "- ⚠️ 设备策略备份丢失（orig_state=existed 但 devicepolicy_orig.xml 不存在），保留当前文件"
            restore_fail "设备策略备份丢失，保留当前文件"
        fi
    else
        rm -f "$XML" || restore_fail "移除设备策略文件失败"
    fi
fi
# 打上 skip 标记：以后开机不再重新应用设备策略
mkdir -p "$BK" && touch "$BK/skip"
rm -f "$BK/target_mv" "$BK/no_adsp_write"
echo "- 已恢复（超级省电功能将恢复可用）"

# --- 6) 恢复官方平滑电量显示 ---
CAP=/sys/class/power_supply/battery/capacity
uv_unbind_capacity "$CAP"
_un=$?
if [ "$_un" -gt 0 ]; then
    echo "- 已恢复官方平滑电量显示（解绑 $_un 层）"
else
    echo "- 电量显示本来就是官方平滑值，无需恢复"
fi

echo ""
echo "=========================================="
rm -f "$BK/restore_pending" || restore_fail "清理待恢复标记失败"
echo "  回写完成！"
echo ""
echo "  已同时完成："
echo "   · 电量计终止电压回写原值"
echo "   · 超级省电设备策略恢复"
echo "   · 官方平滑电量显示恢复"
echo ""
echo "  接下来请："
echo "   1. 关闭（或卸载）本模块"
# 区分两种情况：
#   okv=skip   ：回写后 vbat_uv 已等于目标值（正常路径 —— hook 即时强制）
#   其他       ：hook 未生效（重启后自动跟随）
if [ "$okv" = "skip" ]; then
    echo "   2. vbat_uv 已是 ${TARGET} mV"
else
    echo "   2. vbat_uv 尚未跟随（当前 $(cat "$VBAT" 2>/dev/null) mV），重启后自动生效"
fi
echo "   ⚠️ 卸载后 skip 标记会保留，重装/软重启后仍保持原厂状态"
echo "      若要重新解耦：rm /data/adb/uv2800_backup/skip 后重启"
echo "   3. 验证：cat $VBAT   应显示 ${TARGET}"
echo "      或看驱动内部 fcc：dmesg | grep bs_update_data | tail -1"
echo ""
uv_log "恢复完成：原值 ${TARGET} mV，vbat_uv 刷新=${okv:-0}（skip=本已相等，0=未生效待重启）"
echo "  若以后重新启用本模块，请先执行："
echo "   rm /data/adb/uv2800_backup/skip"
echo "  （否则「禁止超级省电」策略与真实电量显示都不会重新应用）"
echo "=========================================="
