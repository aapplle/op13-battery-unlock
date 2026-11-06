#!/usr/bin/env bash
# 脱离会话的放电监测：每 15 s 一次，设备掉线即记录并退出
DEV="${1:-<DEVICE_IP>:5555}"
OUT="${2:-/tmp/uv_discharge_run3.log}"
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
  ST="$(timeout 12 adb -s "$DEV" shell su -c "sh /data/local/tmp/uv_mon2.sh" 2>/dev/null | tr -d "\r" | tr "\n" " ")"
  echo "$TS [$i] cell_mv=${CELL:-?} level=${CAP:-?} $ST" >> "$OUT"
  sleep 15
done
