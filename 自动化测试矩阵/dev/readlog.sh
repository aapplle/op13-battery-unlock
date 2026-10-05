#!/system/bin/sh
# 只读：不写任何状态
L=/data/adb/uv2800_backup/uv2800.log
echo "=== 日志总行数 ==="; wc -l < $L
echo "=== 最近 130 行 ==="
tail -n 130 $L