#!/system/bin/sh
# ============================================================
# uv2800 - 公共日志函数（v10.7）
#   被 service.sh / action.sh / post-fs-data.sh / uninstall.sh source
#
#   关键日志【三路输出】：
#     1) stdout        —— KernelSU 管理器里可见
#     2) /dev/kmsg     —— dmesg 可见，便于现场排查
#     3) $BK/uv2800.log —— 落盘到备份目录，【卸载不清除】，方便用户反馈
#
#   用法： uv_log "消息内容"
# ============================================================
UV_BK=/data/adb/uv2800_backup
UV_LOG="$UV_BK/uv2800.log"

uv_log() {
    _m="uv2800: $*"
    echo "$_m"
    echo "$_m" > /dev/kmsg 2>/dev/null
    mkdir -p "$UV_BK" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S')] $_m" >> "$UV_LOG" 2>/dev/null
}

# 分隔线：每次脚本执行时打一条，便于把日志按运行分段
# v10.8：日志截断检查从 uv_log（每次调用都做 wc -l）移到此处（每次运行只查一次）
uv_log_sep() {
    # 超过 3000 行时保留后 1500 行，避免无限增长
    _n=$(wc -l < "$UV_LOG" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    if [ "$_n" -gt 3000 ]; then
        tail -1500 "$UV_LOG" > "$UV_LOG.tmp" 2>/dev/null && mv "$UV_LOG.tmp" "$UV_LOG" 2>/dev/null
    fi
    uv_log "---------- $1 ----------"
}
