#!/system/bin/sh
# uv2800 测试：输出最近 N 行模块日志（默认 40）
n=${1:-40}
tail -n "$n" /data/adb/uv2800_backup/uv2800.log 2>/dev/null
