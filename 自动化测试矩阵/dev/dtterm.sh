#!/system/bin/sh
# ============================================================
# 读【当前 ROM 的原厂终止电压策略】(DT ddrc_strategy) 与生效值
#
# 厂商算法（模块 log.sh 的 uv_dt_orig() 复刻的就是这一套）：
#   ① ratio   = 10 × deep_dischg_counts / cc    （cc = battery_cc = 循环次数；仅 0<cc<5000 才做除法）
#   ② region  = ratio 与 oplus,ratio_range 升序比较，≥ 即抬档
#   ③ index_t = 温度与 oplus,temp_range 比较，≤ 归下档
#   ④ 表      = <battery_type>/ddrc_strategy/strategy_ratio_range_<region>/strategy_temp_<温度>
#   ⑤ 行 k    = max{ i : max(0, row[i].f0 − count_cali) ≤ cc }
#   ⑥ 输出    = row[k].vbat1（每行 4 个 u32 大端：f0 阈值, vbat0 关机电压, vbat1 终止电压, idx）
#
# 用途：换 ROM / 内核后核对「原厂终止电压为什么是这个值」，兼容性矩阵留证。
#
# ⚠️ 不要再用 deep_spec,term_coeff 推电压：那张表只决定"用哪张 ddrc 表"，
#    不是电压来源；按 counts 查它会得到偏高的错误值（本机 3350 vs 真值 3250）。
# ============================================================
DT=/sys/firmware/devicetree/base/soc/oplus,mms_gauge

CNT=$(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_counts 2>/dev/null)
CC=$(cat /sys/class/oplus_chg/battery/battery_cc 2>/dev/null)
CALI=$(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali 2>/dev/null)
TEMP=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
case "${CNT:-}" in ''|*[!0-9]*) CNT=0 ;; esac
case "${CALI:-}" in ''|*[!0-9]*) CALI=0 ;; esac

echo "kernel=$(uname -r)"
echo "rom=$(getprop ro.build.display.id)"
echo "battery_type=$(cat /sys/class/oplus_chg/battery/battery_type 2>/dev/null)"
echo "gauge_type=$(cat /sys/class/oplus_chg/battery/gauge_type 2>/dev/null)"
echo "deep_dischg_counts=$CNT  battery_cc=${CC:-<缺失>}  count_cali=$CALI  temp=${TEMP:-<缺失>}"

# 大端 u32 数组 → 空格分隔的十进制
be32_list() {
    set -- $(od -An -tx1 -v "$1" 2>/dev/null | tr -s ' 
' ' ')
    while [ $# -ge 4 ]; do
        printf '%s ' "$((0x$1$2$3$4))"
        shift 4
    done
}

# 找电池子节点（含 ddrc_strategy 的那个）
SUB=""
for d in $DT/*/; do
    [ -d "${d}ddrc_strategy" ] || continue
    SUB=$(basename "$d"); break
done
if [ -z "$SUB" ]; then
    echo "✗ 未找到含 ddrc_strategy 的电池子节点（本 ROM 可能不支持该策略表）"
    exit 1
fi
DD="$DT/$SUB/ddrc_strategy"
echo "battery_node=$SUB"

# ---- ① ratio ----
RATIO=$((10 * CNT))
if [ -n "$CC" ] && [ "$CC" -gt 0 ] 2>/dev/null && [ "$CC" -lt 5000 ] 2>/dev/null; then
    RATIO=$((10 * CNT / CC))
    RSRC="10×counts/cc"
else
    RSRC="10×counts（cc 缺失或越界，按厂商回退）"
fi
echo ""
echo "ratio=$RATIO  （$RSRC）"

# ---- ② region（≥ 即抬档）----
RR=$(be32_list "$DD/oplus,ratio_range")
echo "oplus,ratio_range = $RR"
REGION=0; _i=0
for _b in $RR; do
    [ "$RATIO" -ge "$_b" ] && REGION=$((_i + 1))
    _i=$((_i + 1))
done
case "$REGION" in
    0) RNAME=min ;;
    1) RNAME=low ;;
    2) RNAME=mid_low ;;
    3) RNAME=mid ;;
    4) RNAME=mid_high ;;
    *) RNAME=high ;;
esac
echo "region=$REGION($RNAME)"

# ---- ③ index_t（≤ 归下档）----
TR=$(be32_list "$DD/oplus,temp_range")
echo "oplus,temp_range  = $TR"
IT=3; _i=0
if [ -n "$TEMP" ]; then
    for _b in $TR; do
        # u32 补码：>0x7FFFFFFF 视为负值（mksh 32 位会自动折叠，bash 需显式转换）
        [ "$_b" -gt 2147483647 ] 2>/dev/null && _b=$((_b - 4294967296))
        if [ "$TEMP" -le "$_b" ]; then IT=$_i; break; fi
        _i=$((_i + 1))
    done
    [ "$_i" -ge 3 ] && IT=3
fi
case "$IT" in
    0) TNAME=cold ;;
    1) TNAME=cool ;;
    2) TNAME=normal ;;
    *) TNAME=warm ;;
esac
echo "index_t=$IT($TNAME)"

# ---- ④⑤⑥ 选表 + 选行 + 取值 ----
TBL="$DD/strategy_ratio_range_$RNAME/strategy_temp_$TNAME"
echo ""
echo "table=$TBL"
if [ ! -f "$TBL" ]; then
    echo "✗ 该表不存在 —— 本 ROM 的表结构可能不同，请人工核对"
    exit 1
fi

TERM=""; SHUT=""
set -- $(od -An -tx1 -v "$TBL" 2>/dev/null | tr -s ' 
' ' ')
_n=$#
echo "rows=$((_n / 16))  （每行 4 个 u32：f0 阈值, vbat0 关机电压, vbat1 终止电压, idx）"
while [ $# -ge 16 ]; do
    f0=$((0x$1$2$3$4)); shift 4
    v0=$((0x$1$2$3$4)); shift 4
    v1=$((0x$1$2$3$4)); shift 4
    ix=$((0x$1$2$3$4)); shift 4
    thr=$((f0 - CALI)); [ "$thr" -lt 0 ] && thr=0
    _mark=""
    if [ "$thr" -le "$CC" ] 2>/dev/null; then
        TERM=$v1; SHUT=$v0; _mark="  <= 生效"
    fi
    printf "   f0=%-4d vbat0=%-4d vbat1=%-4d idx=%-2d (阈值 %-4d)%s\n" \
        "$f0" "$v0" "$v1" "$ix" "$thr" "$_mark"
done
echo ""
echo "   → 原厂终止电压 = ${TERM:-<无匹配行>} mV"
echo "   → 电量计关机票 = ${SHUT:-<无匹配行>} mV"

# ---- 交叉核对：模块的 uv_dt_orig()（若已安装）----
LOG=/data/adb/modules/uv2800/log.sh
if [ -f "$LOG" ]; then
    _m=$(  . "$LOG" 2>/dev/null; uv_dt_orig 2>/dev/null )
    echo ""
    echo "   模块 uv_dt_orig() = ${_m:-<失败>} mV"
    if [ -n "$_m" ] && [ -n "$TERM" ] && [ "$_m" != "$TERM" ]; then
        echo "   ⚠️ 两者不一致 —— 请核对本脚本与 log.sh 的算法是否同步"
    fi
fi

echo ""
echo "--- deep_spec 参考（不用于推电压，仅记录）---"
for k in uv_thr vbat_soc count_thr volt_step; do
    f="$DT/$SUB/deep_spec,$k"
    if [ -f "$f" ]; then
        hx=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' 
')
        echo "deep_spec,$k = $((0x$hx))"
    fi
done
