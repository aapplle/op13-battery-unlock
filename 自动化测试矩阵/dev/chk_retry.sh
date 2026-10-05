#!/system/bin/sh
L=/data/adb/uv2800_backup/uv2800.log
echo "=== 日志中 [补写] 出现次数 ==="
grep -c "\[补写\]" $L 2>/dev/null || echo 0
echo "=== ADSP 就绪耗时（探测行）==="
grep -n "ADSP 探测\|主动触发\|触发后 adsp_read" $L | tail -10
echo "=== retry.pid 当前是否存在 ==="
ls -la /data/adb/uv2800_backup/retry.pid 2>/dev/null || echo "  不存在（说明没有后台补写进程在跑）"
echo "=== 是否有残留的补写进程 ==="
ps -A 2>/dev/null | grep -c "service.sh" 