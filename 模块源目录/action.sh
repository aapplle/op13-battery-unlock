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

# 查询模块最后一次【成功写入】的电量计终止电压记录（$BK/adsp_state）。
# 若记录显示已经是原值，就无需 uv_dev 即可跳过回写。
adsp_known() {
    _k=$(cat "$BK/adsp_state" 2>/dev/null | tr -d "[:space:]")
    case "$_k" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_k" = "$1" ] && return 0
    return 1
}
uv_log_sep "action.sh 恢复原值 开始"

PARAM=/sys/module/uv2800/parameters/adsp_write
VBAT=/sys/class/oplus_chg/battery/vbat_uv
VOLT_NOW=/sys/class/power_supply/battery/voltage_now
BK=/data/adb/uv2800_backup

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
        echo "- ⚠️ adsp_orig.txt=$T mV 疑似污染值（DT 表最低档 3000），已隔离，改用厂商标准重算"
        uv_log "adsp_orig.txt=$T 疑似污染，已隔离为 adsp_orig.bad"
        mv -f "$ORIG" "$BK/adsp_orig.bad" 2>/dev/null
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
    echo "【试运行】目标值 ${TARGET} mV 计算完成，未执行任何写入。"
    exit 0
fi

# --- 4) 是否需要真正回写？-------------------------------------------------
# 读写 ADSP 必须用 uv_dev（电量计设备指针）。它由
#   oplus_fg_get_deep_term_volt 的入口 kprobe 在驱动 vote（充电状态变化）时捕获；
#   还可由 deep_dischg 入口补捕获（uv_capture_dev，见下方主动触发）。
#   硬重启 + 越狱后若两条路径都没走到，uv_dev 就是 NULL -> 读不了也写不了 ADSP。
#   但若 $BK/adsp_state 记录显示模块上次写入的就是原值（模块卸载时会清掉该记录），
#   本次就【不需要】回写 —— 直接跳过，继续后面的解绑与策略恢复。
#   ⚠️ 这与 vbat_uv 无关：vbat_uv 是 hook 的即时镜像（实测逐字跟随 uv_target_mv），
#   不需要 vote/插拔 —— 若它不跟随，先查 hook 是否被旁路。
echo "- 当前 vbat_uv: $(cat $VBAT 2>/dev/null) mV"
SKIP_WRITE=0
if adsp_known "$TARGET"; then
    SKIP_WRITE=1
    echo "- 电量计记录 : adsp_state 显示已是原值 ${TARGET} mV -> 无需回写"
    uv_log "adsp_state 记录显示电量计已是原值 ${TARGET} mV，本次跳过回写"
fi

# 不限定越狱模式：任何模式下都先确认 uv_dev 已捕获 ——
#   ① 先主动触发捕获（写 deep_dischg_counts 同值，实测 1 秒内就绪）；
#   ② 仍失败则【中止】回写并提示重启（不给插拔提示，也不做后台补写）。
# 超时一律【中止】而非报假成功；写入后还会读回校验并记录 adsp_state。
if [ "$SKIP_WRITE" = "0" ]; then
    PREAD=/sys/module/uv2800/parameters/adsp_read
    echo 1 > "$PREAD" 2>/dev/null
    READY=$(cat "$PREAD" 2>/dev/null)
    # 未捕获时先主动触发一次（写 deep_dischg_counts 同值）
    if [ -z "$READY" ] || [ "$READY" -le 2000 ] 2>/dev/null; then
        echo ""
        echo "- 尚未捕获【电量计设备指针】，先尝试主动触发..."
        uv_capture_dev
        sleep 1
        echo 1 > "$PREAD" 2>/dev/null
        READY=$(cat "$PREAD" 2>/dev/null)
        if [ -n "$READY" ] && [ "$READY" -gt 2000 ] 2>/dev/null; then
            echo "-    ✅ 已就绪（电量计当前值 $READY mV）"
        fi
    fi
    if [ -z "$READY" ] || [ "$READY" -le 2000 ] 2>/dev/null; then
        # 自动捕获失败（该驱动的 deep_dischg 入口不可用），中止回写
        echo ""
        echo "  ✗✗ 无法捕获电量计设备指针（老版本驱动？），已【中止】回写 ✗✗"
        echo "  请尝试重启手机后再点「执行」。"
        exit 1
    fi
fi
# --- 3.5) ★ 先打 skip 标记 ------------------------------------------
# 【为什么必须在回写之前】service.sh 的解耦分支在探测到 uv_dev 就绪后
# 会把 ADSP 写回解耦目标。若 skip 在回写【之后】才创建，
# 那次写入会把刚恢复的原值覆盖掉（实测：回写后 1 秒被撤销）。
# 这是本脚本唯一的写入窗口；service.sh 的探测循环见到 skip 会立即停手。
mkdir -p "$BK" && touch "$BK/skip"
echo "- 已打上 skip 标记（service.sh 的解耦循环会立即停手）"
echo ""

# 无论是否需要回写，都确保 adsp_orig.txt 存在（可能被隔离为 .bad 后缺失）
if [ ! -f "$BK/adsp_orig.txt" ]; then
    echo "$TARGET" > "$BK/adsp_orig.txt"
    uv_log "已重建 adsp_orig.txt = ${TARGET} mV（原文件缺失/被隔离）"
fi

if [ "$SKIP_WRITE" = "1" ]; then
    echo "- 跳过回写（记录显示已是原值）"
else
    echo "- 写回中 ..."
    echo "$TARGET" > "$PARAM"
    echo "- 写入返回   : $?"
    # 读回校验，一致才记录 adsp_state（供 uv_dev 未捕获时判定）
    _rb=$(echo 1 > /sys/module/uv2800/parameters/adsp_read 2>/dev/null; cat /sys/module/uv2800/parameters/adsp_read 2>/dev/null)
    echo "- 读回校验   : ${_rb} mV"
    if [ "$_rb" = "$TARGET" ]; then
        echo "$TARGET" > "$BK/adsp_state"
    else
        uv_log "⚠️ 回写后读回 ${_rb} mV != 目标 ${TARGET} mV，未记录 adsp_state"
    fi
fi

# ★ 把 hook 强制值设为原值，并【退出恢复模式】让它生效。
#   hook 返回运行时参数 uv_target_mv（默认 2800）；只回写 ADSP 而不改它，
#   hook 仍会把 vbat_uv 强制成 2800，等于没恢复。
#   光改 uv_target_mv 还不够 —— 必须确保 hook 处于生效状态：
#   adsp_write 走 uv_self_write 穿透 hook，回写本身不需要旁路；
#   显式写 resume=1 后 hook 重新生效，vbat_uv 立即被强制成原值 ——
#   实测：hook 生效时 vbat_uv 是 uv_target_mv 的【即时镜像】，改 3000/3100/3250
#   逐字跟随，零延迟、无需任何 vote。
#   （若 vbat_uv 不跟随，唯一原因是 hook 被旁路，不是"需要等 vote/插拔"。）
_P=$(dirname "$PARAM")
if [ -w "$_P/uv_target_mv" ]; then
    echo "$TARGET" > "$_P/uv_target_mv"
    echo "$TARGET" > "$_P/uv_adsp_mv" 2>/dev/null
    echo 1 > "$_P/resume" 2>/dev/null
    sleep 1
    echo "- hook 强制值 : $TARGET mV（uv_target_mv），resume=$(cat "$_P/resume" 2>/dev/null)，vbat_uv=$(cat "$VBAT" 2>/dev/null)"
fi

sleep 2

echo ""
echo "- 内核日志："
dmesg 2>/dev/null | grep "uv2800:" | grep -v "Modules linked" | tail -4

# --- 4.5) 兜底：确认 vbat_uv 已是原值 ---------------------------------------
# 【归因】vbat_uv 不是"驱动缓存"，不需要 vote/插拔刷新：只要 hook 生效
#   （uv_bypass=0），它就是 uv_target_mv 的【即时镜像】—— 改
#   uv_target_mv=3000/3100/3250，vbat_uv 逐字跟随，零延迟。
#   vbat_uv 卡住不跟随，唯一原因是 hook 被旁路（uv_bypass=1）；
#   上方写 resume=1 即恢复，「执行」流程自身不旁路 hook
#   （adsp_write 走 uv_self_write 穿透）。
# 本段保留为【兜底】：万一 hook 参数不可写（老内核）或读回异常，仍给出提示。
CURV=$(cat "$VBAT" 2>/dev/null | tr -d "[:space:]")
if [ "$CURV" != "$TARGET" ]; then
    echo ""
    echo "- ⚠️ hook 未生效（vbat_uv 仍为 $CURV mV，期望 $TARGET mV）"
    echo "-    这不影响 ADSP 回写结果；重启后 vbat_uv 会跟随 uv_target_mv。"
    okv=0
else
    okv=skip        # 回写后已是目标值
fi

# --- 5) 同时恢复「禁止超级省电」设备策略 ---------------------
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

echo ""
echo "- 恢复设备策略（超级省电）..."
su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1
if [ -f "$BK/orig_state" ]; then
    if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ]; then
        if [ -f "$BK/devicepolicy_orig.xml" ]; then
            cp -f "$BK/devicepolicy_orig.xml" "$XML"
            chown system:system "$XML" 2>/dev/null
            chmod 600 "$XML" 2>/dev/null
        else
            # 原文件存在但备份丢失 → 不动文件，报警
            echo "- ⚠️ 设备策略备份丢失（orig_state=existed 但 devicepolicy_orig.xml 不存在），保留当前文件"
            uv_log "⚠️ 设备策略备份丢失，保留当前文件"
        fi
    else
        rm -f "$XML"
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
