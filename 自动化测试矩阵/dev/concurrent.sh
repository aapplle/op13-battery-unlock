#!/system/bin/sh
# ============================================================
# uv2800 测试：并发竞态（T9.3 用）
#   模拟"service.sh 解耦循环"与"用户点执行(action.sh)"同时发生
#   输出：并发结束后的残留进程数与最终状态
# ============================================================
BK=/data/adb/uv2800_backup
M=/data/adb/modules/uv2800
LOG=/data/local/tmp/uvtest/last_concurrent.log

rm -f $BK/skip
: > $LOG
echo "[concurrent] 启动 3×service.sh + 1×action.sh" >> $LOG
i=1
while [ $i -le 3 ]; do
  sh $M/service.sh >> $LOG 2>&1 &
  i=$((i+1))
done
sh $M/action.sh >> $LOG 2>&1 &

sleep 15

n=0
for p in /proc/[0-9]*; do
  c=$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ')
  case "$c" in *uv2800/service.sh*) n=$((n+1));; esac
done
echo "residual_svc=$n"
echo "concurrent_done=1"
