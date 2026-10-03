#!/system/bin/sh
# KernelSU post-fs-data: 加载 uv2800.ko
MODDIR=${0%/*}

# v10.7：日志函数（stdout + dmesg + 落盘到备份目录）
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_log_sep "post-fs-data.sh 开始"

# 等待 oplus_chg_v2 加载完成（kprobe 需要它的符号），最多 30 秒
i=0
while [ $i -lt 30 ]; do
    [ -d /sys/module/oplus_chg_v2 ] && break
    sleep 1
    i=$((i+1))
done

# v10.7：若模块已在内存（软重启时 KSU 会重跑本脚本），【不要】rmmod+insmod，
# 否则 uv_dev 会被清空，用户就必须重新插拔一次充电器。
if lsmod | grep -q "^uv2800"; then
    uv_log "post-fs-data 模块已在内存，跳过 insmod（保留 uv_dev）"
    return 0 2>/dev/null || exit 0
fi

# v10.8：删掉旧版遗留的 rmmod（上方已「已加载则跳过」，此处必为未加载，属死代码）
insmod "$MODDIR/uv2800.ko"
uv_log "post-fs-data insmod rc=$? (waited ${i}s)"
