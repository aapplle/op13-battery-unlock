#!/system/bin/sh
echo "=== modules / modules_update ==="
ls /data/adb/modules/ 2>/dev/null | sed "s/^/  modules\/: /"
ls /data/adb/modules_update/ 2>/dev/null | sed "s/^/  update\/: /"
echo "=== uv2800 目录内容 ==="
ls /data/adb/modules/uv2800/ 2>/dev/null | sed "s/^/  /" || echo "  (不存在)"
echo "=== 驱动侧状态（模块不在也能读）==="
echo "  vbat_uv=$(cat /sys/class/oplus_chg/battery/vbat_uv)"
echo "  capacity=$(cat /sys/class/power_supply/battery/capacity)  chip_soc=$(cat /sys/class/oplus_chg/battery/chip_soc)"
echo "  bind 层数=$(grep -c chip_soc /proc/self/mountinfo)"
echo "  skip=$([ -f /data/adb/uv2800_backup/skip ] && echo 有 || echo 无)"
echo "  adsp_orig=$(cat /data/adb/uv2800_backup/adsp_orig.txt 2>/dev/null)"
echo "=== 最近日志 ==="
tail -6 /data/adb/uv2800_backup/uv2800.log 2>/dev/null