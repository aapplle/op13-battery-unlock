#!/system/bin/sh
# 标准启动模式下的早期加载脚本：等待充电驱动就绪后加载 uv2800.ko
MODDIR=${0%/*}

[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_log_sep "post-fs-data.sh 开始"

# kprobe 依赖 oplus_chg_v2 导出的符号，最多等待 30 秒
i=0
while [ $i -lt 30 ]; do
    [ -d /sys/module/oplus_chg_v2 ] && break
    sleep 1
    i=$((i+1))
done

# 软重启时模块已在内核中，跳过加载以保留已捕获的 uv_dev 指针
if lsmod | grep -q "^uv2800"; then
    uv_log "post-fs-data 模块已在内存，跳过 insmod（保留 uv_dev）"
    return 0 2>/dev/null || exit 0
fi

insmod "$MODDIR/uv2800.ko"
uv_log "post-fs-data insmod rc=$? (waited ${i}s)"
uv_log_kver
