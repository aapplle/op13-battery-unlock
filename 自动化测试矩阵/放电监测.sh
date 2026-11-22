#!/usr/bin/env bash
# 脱离会话的放电监测：每 15 s 一次，设备掉线即记录并退出
# 用法：./放电监测.sh <DEVICE_IP:5555 或 adb serial> [日志路径]
DEV="${1:-}"
OUT="${2:-/tmp/uv_discharge.log}"
if [ -z "$DEV" ] || [ "$DEV" = "<DEVICE_IP>:5555" ]; then
  DEV="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
[ -n "$DEV" ] || { echo "用法: $0 <adb_serial_or_ip:port> [out_log]"; exit 2; }
echo "启动 $(date "+%m-%d %H:%M:%S")  设备=$DEV  日志=$OUT" > "$OUT"
i=0
while true; do
  i=$((i+1))
  TS="$(date "+%m-%d %H:%M:%S")"
  if ! adb -s "$DEV" get-state >/dev/null 2>&1; then
    echo "$TS OFFLINE（第 $i 次轮询后掉线 ⇒ 已关机）" >> "$OUT"; break
  fi
  CELL="$(timeout 12 adb -s "$DEV" shell "dumpsys battery 2>/dev/null | grep -E '^ *voltage: [0-9]+' | head -1" 2>/dev/null | tr -dc "0-9")"
  CAP="$(timeout 12 adb -s "$DEV" shell "dumpsys battery 2>/dev/null | grep -E '^ *level: [0-9]+' | head -1" 2>/dev/null | tr -dc "0-9")"
  ST="$(timeout 12 adb -s "$DEV" shell "su -c 'echo chip_soc=\$(cat /sys/class/oplus_chg/battery/chip_soc 2>/dev/null) vbat_uv=\$(cat /sys/class/oplus_chg/battery/vbat_uv 2>/dev/null) rm=\$(cat /sys/class/oplus_chg/battery/battery_rm 2>/dev/null) fcc=\$(cat /sys/class/oplus_chg/battery/battery_fcc 2>/dev/null) temp=\$(cat /sys/class/power_supply/battery/temp 2>/dev/null)'" 2>/dev/null | tr -d "\r" | tr "\n" " ")"
  echo "$TS [$i] cell_mv=${CELL:-?} level=${CAP:-?} $ST" >> "$OUT"
  sleep 15
done
