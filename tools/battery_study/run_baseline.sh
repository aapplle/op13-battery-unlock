#!/system/bin/sh
# 运行入口：支持等待真实拔线事件。有限样本为诊断，无限样本为完整基线。
# 用法：sh run_baseline.sh OUTDIR --start [unplug|延迟秒=60] [样本数=0(不限)]
set -eu
DIR=${0%/*}
OUT=${1:?需要输出目录}
[ "${2:-}" = --start ] || { echo "需要 --start 显式启动" >&2; exit 2; }
DELAY=${3:-60}
SAMPLES=${4:-0}
case "$SAMPLES" in ''|*[!0-9]*) exit 2 ;; esac
case "$DELAY" in unplug) ;; ''|*[!0-9]*) exit 2 ;; *) [ "$DELAY" -le 600 ] || exit 2 ;; esac
. "$DIR/preflight.sh"
study_preflight smoke || exit 1
[ ! -e "$OUT" ] || exit 1
MODE=baseline
[ "$SAMPLES" -eq 0 ] || MODE=diagnostic
WAKE_NAME=op13_baseline_$$
W1= W2= LOGGER=
WAKE_HELD=0
cleanup() {
    for pid in "$LOGGER" "$W1" "$W2"; do
        case "$pid" in ''|*[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac
    done
    if [ "$WAKE_HELD" = 1 ]; then
        echo "$WAKE_NAME" > /sys/power/wake_unlock 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
# 临时保持 CPU 可运行，避免 Android 熄屏后挂起采样；退出即释放。
echo "$WAKE_NAME" > /sys/power/wake_lock
WAKE_HELD=1
if [ "$DELAY" = unplug ]; then
    echo "WAITING_FOR_UNPLUG mode=$MODE timeout=300s"
    ATTEMPT=0
    while ! CHECK=$(study_preflight "$MODE" 2>&1); do
        if [ "$ATTEMPT" -ge 150 ]; then
            echo "START_TIMEOUT: $CHECK"; exit 1
        fi
        [ $((ATTEMPT % 10)) -ne 0 ] || echo "$CHECK"
        sleep 2
        ATTEMPT=$((ATTEMPT+1))
    done
else
    sleep "$DELAY"
    study_preflight "$MODE" || exit 1
fi
echo "STARTED utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ') mode=$MODE samples=$SAMPLES"
# 两个固定 shell 计算线程；不改变亮度、充电、温控或系统设置。
worker() { while :; do :; done; }
worker & W1=$!
worker & W2=$!
sh "$DIR/collect.sh" "$OUT" "$MODE" 5 "$SAMPLES" & LOGGER=$!
wait "$LOGGER"
