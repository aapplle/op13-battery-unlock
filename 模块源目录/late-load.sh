#!/system/bin/sh
# 越狱（late-load）模式专用加载脚本
# 越狱模式下系统已完全启动，post-fs-data.sh 不会运行，由本脚本加载内核模块。
MODDIR=${0%/*}

[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }

if lsmod | grep -q "^uv2800"; then
    uv_log "late-load.sh 模块已加载，跳过 insmod（重复执行场景）"
else
    insmod "$MODDIR/uv2800.ko"
    uv_log "late-load.sh insmod rc=$?"
    command -v uv_log_kver >/dev/null 2>&1 && uv_log_kver
fi
