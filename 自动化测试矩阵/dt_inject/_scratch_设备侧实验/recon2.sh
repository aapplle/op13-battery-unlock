#!/system/bin/sh
echo "=== cali node exists? ==="
[ -e /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali ] && echo YES || echo NO
ls -la /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali 2>&1
echo "=== real reads ==="
echo "cnt=[$(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_counts 2>/dev/null)]"
echo "cc=[$(cat /sys/class/oplus_chg/battery/battery_cc 2>/dev/null)]"
echo "cali=[$(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali 2>/dev/null)]"
echo "temp=[$(cat /sys/class/power_supply/battery/temp 2>/dev/null)]"
echo "batt=[$(cat /sys/class/oplus_chg/battery/battery_type 2>/dev/null)]"
echo "=== tables per region ==="
DTB=/sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy
for r in strategy_ratio_range_min strategy_ratio_range_low strategy_ratio_range_mid_low strategy_ratio_range_mid strategy_ratio_range_mid_high strategy_ratio_range_high; do
  echo "REGION $r:"
  ls -la "$DTB/$r/" 2>&1
done
