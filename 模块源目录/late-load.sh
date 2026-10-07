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
#    或手动 echo <mV> > /sys/module/uv2800/parameters/adsp_write
#    （写之前请确认 uv_dev 已捕获）。
#
#    uv_dev 由模块主动触发一次驱动调用来捕获（写 deep_dischg_counts 同值），
#    不依赖插拔充电器。
# ============================================================
MODDIR=${0%/*}

# 接入公共日志（三路输出：stdout + /dev/kmsg + $BK/uv2800.log）
#   若只做裸 echo，越狱路线的日志里【完全看不到】本脚本执行过，
#   排查时无法区分"没跑"和"跑了但失败"。
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_lock || exit 1

if lsmod | grep -q "^uv2800"; then
    uv_log "late-load.sh 模块已加载，跳过 insmod（重复执行场景）"
else
    if insmod "$MODDIR/uv2800.ko"; then
        uv_log "late-load.sh insmod 成功"
    else
        _load_rc=$?
        uv_log "late-load.sh insmod 失败 rc=$_load_rc"
        exit "$_load_rc"
    fi
    # 抓内核自报的 profile 落盘（dmesg 约 10 分钟就被冲掉）
    command -v uv_log_kver >/dev/null 2>&1 && uv_log_kver
fi
