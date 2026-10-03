#!/system/bin/sh
# ============================================================
# uv2800 - late-load.sh（KernelSU 越狱 / late-load 模式专用）
#
# 越狱模式下 KernelSU 在系统完全启动后才加载，
# `post-fs-data.sh` **不会运行**，由本脚本替代（官方推荐做法）。
# 本阶段在 OverlayFS 挂载之前执行，时机与标准启动的 post-fs-data 类似。
#
# 与 post-fs-data.sh 的两点区别：
#   1) 系统已完全启动，oplus_chg_v2 必然已加载 -> 不需要等待循环
#   2) 软重启后管理器可能重跑 `ksud late-load` -> 本脚本会被重复执行
#      所以「已加载则跳过」，避免重复 insmod 破坏已有状态（uv_dev 等）
#
#    回写电量计必须读实时 DT 算原值，唯一入口是 action.sh（操作按钮）
#    或手动 echo <mV> > /sys/module/uv2800/parameters/restore。
#
# ⚠️ 越狱模式的一个限制（已实测确认）：
#    驱动 oplus_fg_get_deep_term_volt 只在【开机时】被调用一次，越狱模式下
#    模块加载太晚，错过了那次调用 -> 拿不到驱动设备指针 -> 写不进电量计 ADSP。
#    实测：**插拔一次充电器**会让驱动重新投票终止电压并调用 getter，模块随即
#    捕获指针，ADSP 读写立刻恢复正常（无需重启）。
#    service.sh 已内置后台补写（最多等 1 小时），action.sh 会提示并等待。
# ============================================================
MODDIR=${0%/*}

if lsmod | grep -q "^uv2800"; then
    echo "uv2800: late-load.sh 模块已加载，跳过 insmod（重复执行场景）"
else
    insmod "$MODDIR/uv2800.ko"
    echo "uv2800: late-load.sh insmod rc=$?"
fi
