#!/system/bin/sh
# ============================================================
# uv2800 测试：设备状态快照
#   输出 key=value，每行一个 —— 主机侧所有断言的唯一数据源
#   用法（主机）：adb shell "su -c 'sh /data/local/tmp/uvtest/snap.sh'"
# ============================================================
P=/sys/module/uv2800/parameters
BK=/data/adb/uv2800_backup
B=/sys/class/oplus_chg/battery
CAP=/sys/class/power_supply/battery/capacity
KEY=oplus_diable_super_power_saving_mode

g() { v=$(cat "$1" 2>/dev/null | tr -d '[:space:]'); [ -z "$v" ] && v="?"; echo "$v"; }
f() { [ -e "$1" ] && echo yes || echo no; }

echo "module_loaded=$(lsmod 2>/dev/null | grep -c '^uv2800')"
echo "param_target=$(g $P/uv_target_mv)"
echo "param_adsp=$(g $P/uv_adsp_mv)"
echo "param_resume=$(g $P/resume)"
echo "param_debug=$(g $P/adsp_debug)"
echo 1 > $P/adsp_read 2>/dev/null
echo "adsp_read=$(g $P/adsp_read)"
echo "vbat_uv=$(g $B/vbat_uv)"
echo "chip_soc=$(g $B/chip_soc)"
echo "capacity=$(g $CAP)"
echo "bind_layers=$(grep -c chip_soc /proc/self/mountinfo 2>/dev/null)"
echo "skip=$(f $BK/skip)"
echo "adsp_orig=$(g $BK/adsp_orig.txt)"
echo "restore_target=$(g $BK/restore_target_mv)"
echo "restore_pending=$(f $BK/restore_pending)"
echo "adsp_state=$(g $BK/adsp_state)"
echo "target_file=$(g $BK/target_mv)"
echo "orig_state=$(g $BK/orig_state)"
echo "applied=$(f $BK/applied)"
echo "bad_file=$(f $BK/adsp_orig.bad)"
echo "count=$(g /sys/devices/virtual/oplus_chg/common/deep_dischg_counts)"
echo "retry_proc=$(ps -A 2>/dev/null | grep -c '[a]dsp_retry')"
echo "svc_proc=$(ps -A 2>/dev/null | grep -c '[u]v2800/service')"
echo "usb_online=$(grep POWER_SUPPLY_ONLINE /sys/class/power_supply/usb/uevent 2>/dev/null | cut -d= -f2)"
echo "fcc=$(g $B/battery_fcc)"
echo "policy_out=$(su 1000 -c "service call oplusdevicepolicy 4 s16 $KEY i32 1" 2>&1 | tr '\n' ' ' | cut -c1-120)"
echo "ts=$(date +%s)"
