#!/system/bin/sh
P=/sys/module/uv2800/parameters
M=/data/adb/modules/uv2800
V=/sys/class/oplus_chg/battery/vbat_uv
echo "=== 1) rmmod 前（解耦态）==="
echo "  模块=$(lsmod | grep -c ^uv2800)  uv_target_mv=$(cat $P/uv_target_mv)  vbat_uv=$(cat $V)"
echo ""
echo "=== 2) rmmod ==="
rmmod uv2800; echo "  rc=$?"
echo "=== 3) rmmod 后逐秒观察 vbat_uv（驱动尚未重算）==="
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf "  +%2ds  vbat_uv=%s\n" "$i" "$(cat $V)"
  sleep 1
done
echo ""
echo "=== 4) 恢复：insmod + service.sh ==="
insmod $M/uv2800.ko; echo "  insmod rc=$?"
sh $M/service.sh >/dev/null 2>&1
sleep 2
echo "  模块=$(lsmod | grep -c ^uv2800)  uv_target_mv=$(cat $P/uv_target_mv)  vbat_uv=$(cat $V)"
echo 1 > $P/adsp_read; echo "  adsp_read=$(cat $P/adsp_read)"