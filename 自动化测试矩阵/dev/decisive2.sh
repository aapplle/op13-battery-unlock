#!/system/bin/sh
P=/sys/module/uv2800/parameters
V=/sys/class/oplus_chg/battery/vbat_uv
M=/data/adb/modules/uv2800
echo "=== 前置：模块在，uv_target_mv=3250，vbat_uv 应为 3250 ==="
echo "  module=$(lsmod | grep -c ^uv2800)  uv_target_mv=$(cat $P/uv_target_mv)  vbat_uv=$(cat $V)"
echo ""
echo "=== rmmod 并逐秒观察 ==="
rmmod uv2800; echo "  rmmod rc=$?"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf "  +%2ds  vbat_uv=%s\n" "$i" "$(cat $V)"; sleep 1; done
echo ""
echo "=== 判据 ==="
echo "  全程 3250 → 【过期值】假设成立（修复可行：rmmod 前复位即可）"
echo "  变/停在 2800 → 【主动回退】假设成立（KimiK3 对，脚本无法修复）"
echo ""
echo "=== 恢复 ==="
insmod $M/uv2800.ko 2>/dev/null; echo "  insmod rc=$?"
sh $M/service.sh >/dev/null 2>&1; sleep 2
echo "  module=$(lsmod | grep -c ^uv2800)  uv_target_mv=$(cat $P/uv_target_mv 2>/dev/null)  vbat_uv=$(cat $V)"