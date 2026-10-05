#!/bin/sh
# 便捷包装：见 run_cases.py 顶部说明
exec python3 "$(dirname "$0")/run_cases.py" "$@"
