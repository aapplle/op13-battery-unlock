#!/system/bin/sh
# KernelSU post-fs-data: 加载 uv2800.ko
MODDIR=${0%/*}

# 等待 oplus_chg_v2 加载完成（kprobe 需要它的符号），最多 30 秒
i=0
while [ $i -lt 30 ]; do
    [ -d /sys/module/oplus_chg_v2 ] && break
    sleep 1
    i=$((i+1))
done

# 先卸载旧实例，避免重复
rmmod uv2800 2>/dev/null

insmod "$MODDIR/uv2800.ko"
echo "uv2800: post-fs-data insmod rc=$? (waited ${i}s)"
