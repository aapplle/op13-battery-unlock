#!/system/bin/sh
# 恢复原厂状态脚本：
#   1. 确定原厂终止电压（优先读首次备份 adsp_orig.txt，缺失或异常时从设备树重算）
#   2. 写入 skip 标记，阻止并发的 service.sh 覆盖恢复结果
#   3. 将原厂值写回 ADSP 并同步内核 hook 参数
#   4. 恢复超级省电设备策略并解绑真实电量挂载
#
# 支持试运行模式：UV2800_DRYRUN=1 sh restore.sh（仅计算原值，不执行写入）

MODDIR=${0%/*}
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
klog() { uv_log "$@"; }
command -v adsp_known >/dev/null 2>&1 || adsp_known() { return 1; }
uv_log_sep "restore.sh 恢复原值 开始"

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

# 检查当前单芯电压，低于原厂终止电压附近时提示钳位风险
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

# 1. 获取原厂终止电压：优先采用备份，小于 3000mV 时视为污染并隔离，退回设备树重算
TARGET=""
ORIG="$BK/adsp_orig.txt"
if [ -f "$ORIG" ]; then
    T=$(cat "$ORIG" 2>/dev/null | tr -d "[:space:]")
    case "$T" in ''|*[!0-9]*) T="" ;; esac
    if [ -n "$T" ] && [ "$T" -lt 3000 ] 2>/dev/null; then
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

# 2. 检查是否需要回写 ADSP，并确认 uv_dev 已捕获
echo "- 当前 vbat_uv: $(cat $VBAT 2>/dev/null) mV"
SKIP_WRITE=0
if adsp_known "$TARGET"; then
    SKIP_WRITE=1
    echo "- 电量计记录 : adsp_state 显示已是原值 ${TARGET} mV -> 无需回写"
    uv_log "adsp_state 记录显示电量计已是原值 ${TARGET} mV，本次跳过回写"
fi

if [ "$SKIP_WRITE" = "0" ]; then
    PREAD=/sys/module/uv2800/parameters/adsp_read
    echo 1 > "$PREAD" 2>/dev/null
    READY=$(cat "$PREAD" 2>/dev/null)
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
        echo ""
        echo "  ✗✗ 无法捕获电量计设备指针（老版本驱动？），已【中止】回写 ✗✗"
        echo "  请尝试重启手机后，在 WebUI 中重新点「恢复原厂」。"
        exit 1
    fi
fi

# 3. 在写 ADSP 前先创建 skip 标记，防止并发运行的 service.sh 将 ADSP 重新写回解耦值
mkdir -p "$BK" && touch "$BK/skip"
echo "- 已打上 skip 标记（service.sh 的解耦循环会立即停手）"
echo ""

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
    _rb=$(echo 1 > /sys/module/uv2800/parameters/adsp_read 2>/dev/null; cat /sys/module/uv2800/parameters/adsp_read 2>/dev/null)
    echo "- 读回校验   : ${_rb} mV"
    if [ "$_rb" = "$TARGET" ]; then
        echo "$TARGET" > "$BK/adsp_state"
    else
        uv_log "⚠️ 回写后读回 ${_rb} mV != 目标 ${TARGET} mV，未记录 adsp_state"
    fi
fi

# 同步内核 hook 强制值为原厂值并确保 hook 处于启用状态
_P=$(dirname "$PARAM")
if [ -w "$_P/uv_target_mv" ]; then
    echo "$TARGET" > "$_P/uv_shutdown_mv" 2>/dev/null
    echo "$TARGET" > "$_P/uv_target_mv"
    echo "$TARGET" > "$_P/uv_term_mv" 2>/dev/null
    echo "$TARGET" > "$_P/uv_adsp_mv" 2>/dev/null
    echo 1 > "$_P/resume" 2>/dev/null
    sleep 1
    echo "- hook 强制值 : $TARGET mV（uv_target_mv），resume=$(cat "$_P/resume" 2>/dev/null)，vbat_uv=$(cat "$VBAT" 2>/dev/null)"
fi

sleep 2

echo ""
echo "- 内核日志："
dmesg 2>/dev/null | grep "uv2800:" | grep -v "Modules linked" | tail -4

CURV=$(cat "$VBAT" 2>/dev/null | tr -d "[:space:]")
if [ "$CURV" != "$TARGET" ]; then
    echo ""
    echo "- ⚠️ hook 未生效（vbat_uv 仍为 $CURV mV，期望 $TARGET mV）"
    echo "-    这不影响 ADSP 回写结果；重启后 vbat_uv 会跟随 uv_target_mv。"
    okv=0
else
    okv=skip
fi

# 4. 恢复设备策略与官方平滑电量显示
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode
CAP=/sys/class/power_supply/battery/capacity
CAPUE=/sys/class/power_supply/battery/uevent
[ -f "$MODDIR/lib/features.sh" ] && . "$MODDIR/lib/features.sh"

echo ""
echo "- 恢复设备策略（超级省电）..."
if command -v feature_policy_restore >/dev/null 2>&1; then
    feature_policy_restore
else
    su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1
    rm -f "$BK/applied"
fi
mkdir -p "$BK" && touch "$BK/skip"
rm -f "$BK/target_mv" "$BK/no_adsp_write"
echo "- 已恢复（超级省电功能将恢复可用）"

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
