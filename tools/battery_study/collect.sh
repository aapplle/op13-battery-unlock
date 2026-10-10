#!/system/bin/sh
# 原始数据采样。smoke 可带 USB；baseline 必须完全断开外部供电。
# 用法：sh collect.sh OUTDIR [smoke|diagnostic|baseline] [间隔秒=5] [样本数=0(不限)]
set -eu
DIR=${0%/*}
OUT=${1:?需要新的输出目录}
MODE=${2:-smoke}
INTERVAL=${3:-5}
LIMIT=${4:-0}
case "$MODE" in smoke|diagnostic|baseline) ;; *) exit 2 ;; esac
case "$INTERVAL:$LIMIT" in *[!0-9:]*|:*) exit 2 ;; esac
[ "$INTERVAL" -ge 1 ] && [ "$INTERVAL" -le 60 ] || exit 2
. "$DIR/preflight.sh"
study_preflight "$MODE" || exit 1
mkdir "$OUT" || { echo "输出目录已存在或创建失败，停止以保护已有数据" >&2; exit 1; }
chmod 755 "$OUT"
finish() {
    printf '%s\t%s\n' "$(cut -d ' ' -f 1 /proc/uptime)" "$1" >> "$OUT/events.tsv"
}
trap 'finish interrupted; exit 130' INT TERM HUP
{
    echo "mode=$MODE"
    echo "interval_seconds=$INTERVAL"
    echo "started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "kernel=$(uname -r)"
    echo "model=$(getprop ro.product.model)"
    echo "build=$(getprop ro.build.display.id)"
    echo "battery_type=$(cat /sys/class/oplus_chg/battery/battery_type)"
    echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
    echo "current_scale_to_pack=UNCONFIRMED"
    echo "voltage_scale_to_pack=UNCONFIRMED"
    echo "endpoint=UNCONFIRMED"
} > "$OUT/meta.txt"
cat /sys/class/power_supply/battery/uevent > "$OUT/initial-battery-uevent.txt"
cat /proc/oplus-votable/TARGET_TERM_VOLTAGE/status > "$OUT/initial-term-target.txt"
cat /proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/status > "$OUT/initial-shutdown-votes.txt"
HEADER=$(cat /sys/class/oplus_chg/battery/battery_log_head)
printf 'uptime_s%s,power_status,usb_online,wireless_online,android_current_now_raw,charge_counter_raw,voltage_now_raw\n' "$HEADER" > "$OUT/samples.csv"
finish started
N=0
while :; do
    T=$(cut -d ' ' -f 1 /proc/uptime)
    CONTENT=$(cat /sys/class/oplus_chg/battery/battery_log_content)
    STATUS=$(cat /sys/class/power_supply/battery/status)
    USB=$(cat /sys/class/power_supply/usb/online)
    WIRELESS=$(cat /sys/class/power_supply/wireless/online)
    CURRENT=$(cat /sys/class/power_supply/battery/current_now)
    COUNTER=$(cat /sys/class/power_supply/battery/charge_counter)
    VOLTAGE=$(cat /sys/class/power_supply/battery/voltage_now)
    printf '%s%s,%s,%s,%s,%s,%s,%s\n' "$T" "$CONTENT" "$STATUS" "$USB" "$WIRELESS" "$CURRENT" "$COUNTER" "$VOLTAGE" >> "$OUT/samples.csv"
    TEMP=$(printf '%s\n' "$CONTENT" | cut -d, -f2)
    case "$TEMP" in ''|*[!0-9-]*) finish invalid_temperature; exit 1 ;; esac
    if [ "$MODE" != smoke ]; then
        WIRED=$(printf '%s\n' "$CONTENT" | cut -d, -f9)
        IBAT=$(printf '%s\n' "$CONTENT" | cut -d, -f6)
        if ! study_power_is_discharge "$USB" "$WIRELESS" "$WIRED" "$STATUS" "$IBAT"; then
            finish external_power_or_not_discharging; exit 1
        fi
        # 控制测量条件；达到 40°C 就终止本次负载，而非修改温控。
        if [ "$TEMP" -ge 400 ]; then finish temperature_limit; exit 1; fi
    fi
    if [ -e "$OUT/STOP" ]; then finish user_stop; exit 0; fi
    N=$((N+1))
    if [ "$LIMIT" -gt 0 ] && [ "$N" -ge "$LIMIT" ]; then finish sample_limit; exit 0; fi
    sleep "$INTERVAL"
done
