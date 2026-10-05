#!/system/bin/sh
P=/sys/module/uv2800/parameters
V=/sys/class/oplus_chg/battery/vbat_uv
M=/data/adb/modules/uv2800
echo "=== 1) 模块在，先把 uv_target_mv 设成原厂 3250（hook 会即时镜像）==="
echo "  设前: uv_target_mv=$(cat $P/uv_target_mv)  vbat_uv=$(cat $V)"
echo 3250 > $P/uv_target_mv
sleep 1
echo "  设后: uv_target_mv=$(cat $P/uv_target_mv)  vbat_uv=$(cat $V)"
echo ""
echo "=== 2) rmmod ==="
rmmod uv2800; echo "  rc=$?"
echo "=== 3) rmmod 后逐秒观察（判据：3250=过期值假设 / 2800=主动回退假设）==="
for i in 1 2 3 4 5 6 7 8 9 10; do printf "  +%2ds  vbat_uv=%s\n" "$i" "$(cat $V)"; sleep 1; done
echo ""
echo "=== 4) 恢复模块（insmod + service.sh 解耦）==="
insmod $M/uv2800.ko 2>/dev/null; echo "  insmod rc=$?"
sh $M/service.sh >/dev/null 2>&1; sleep 2
echo "  模块=$(lsmod | grep -c ^uv2800)  uv_target_mv=$(cat $P/uv_target_mv)  vbat_uv=$(cat $V)"