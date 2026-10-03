#!/system/bin/sh
# ============================================================
# uv2800 - customize.sh（模块安装时由 KernelSU 执行，输出用户可见）
#   仅在越狱(late-load)模式下提示：刷入后需插拔一次充电器，让驱动
#   vote 终止电压 -> 调用 getter -> 模块捕获 uv_dev；随后脚本主动 adsp_write 解耦。
#   标准(built-in/lkm)模式开机 vote 时模块已就绪，【无需】插拔，直接跳过。
# ============================================================

# KSU_LATE_LOAD：越狱(late-load)时为 "1"，否则未设置（KernelSU 官方约定）
if [ "$KSU_LATE_LOAD" != "1" ]; then
    ui_print "- 标准模式：开机 vote 时模块已就绪，无需插拔充电器"
    return 0 2>/dev/null || exit 0
fi

ui_print "**********************************************"
ui_print "  检测到越狱(late-load)模式"
ui_print "  重启后需【插拔一次充电器】完成解耦"
ui_print "  · 无时间限制：任意时刻插拔一次即可"
ui_print "  · 不插拔不影响关机保护(2800mV已生效)"
ui_print "  · 只是解耦(fcc/SOC)与卸载回写暂不就绪"
ui_print "**********************************************"

# 安装阶段模块尚未加载（late-load 在重启/软重启后才 insmod），无法读写
# ADSP，这里只提示。真正的解耦与指针捕获发生在重启并插拔充电器之后：
#   · 回写指针捕获：vote 触发 -> getter 调用 -> 模块捕获 uv_dev（卸载回写用）
#   · 解耦(写 2600)：脚本检测到 uv_dev 就绪后【主动 adsp_write】
#     （v10.6 修正：驱动只在 term 值变化时才写，被动拦截 setter 不可靠）
#   · 一次插拔即捕获；同一次开机内安装解耦与卸载回写共用，无需重复插拔
# 若本次是【重装】且模块已加载，可在此等待插拔确认（否则跳过，重启后自行插拔）。

P=/sys/module/uv2800/parameters
if [ -w "$P/adsp_read" ]; then
    echo 1 > "$P/adsp_read" 2>/dev/null
    _c=$(cat "$P/adsp_read" 2>/dev/null)
    if [ -z "$_c" ] || [ "$_c" -le 2000 ] 2>/dev/null; then
        ui_print "- 模块已加载但未捕获指针，请现在【插拔一次充电器】..."
        i=0; ok=0
        while [ "$i" -lt 30 ]; do
            sleep 2
            echo 1 > "$P/adsp_read" 2>/dev/null
            _c=$(cat "$P/adsp_read" 2>/dev/null)
            if [ -n "$_c" ] && [ "$_c" -gt 2000 ] 2>/dev/null; then
                ui_print "- ✅ 已就绪（电量计当前值 $_c mV）"; ok=1; break
            fi
            i=$((i+1))
        done
        [ "$ok" != "1" ] && ui_print "- 未检测到插拔；之后任意时刻插拔一次即可（无时间限制）"
    else
        ui_print "- ✅ 模块已就绪（电量计当前值 $_c mV）"
    fi
else
    ui_print "- 重启后任意时刻插拔一次充电器即可生效（无时间限制）"
fi

return 0 2>/dev/null || exit 0