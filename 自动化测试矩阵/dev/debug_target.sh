#!/system/bin/sh
BK=/data/adb/uv2800_backup
P=/sys/module/uv2800/parameters
M=/data/adb/modules/uv2800
echo "=== 设备上的 service.sh 是否含 target_mv 逻辑 ==="
grep -n "target_mv\|V_S=" $M/service.sh | head -12
echo ""
echo "=== 手工：写 target_mv=2900 并跑 service.sh ==="
echo 2900 > $BK/target_mv
echo "  target_mv 文件 = $(cat $BK/target_mv)"
sh $M/service.sh 2>&1 | grep -E "target|关机电压|V_s|解耦|uv_target" | head -10
echo "  uv_target_mv 参数 = $(cat $P/uv_target_mv)"
echo "  vbat_uv = $(cat /sys/class/oplus_chg/battery/vbat_uv)"
echo 1 > $P/adsp_read; echo "  adsp_read = $(cat $P/adsp_read)"
echo ""
echo "=== 恢复 2800 ==="
echo 2800 > $BK/target_mv
sh $M/service.sh >/dev/null 2>&1
echo "  uv_target_mv = $(cat $P/uv_target_mv)  adsp = $(echo 1 > $P/adsp_read; cat $P/adsp_read)"