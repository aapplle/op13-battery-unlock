#!/system/bin/sh
# ============================================================
# uv2800 - customize.sh（模块安装时由 KernelSU 执行，输出用户可见）
# ============================================================

rm -f /data/adb/uv2800_backup/uninstall_verified
ui_print "- 点「执行」可一键安全卸载：先恢复校验，成功后安排删除"

if [ "$KSU_LATE_LOAD" != "1" ]; then
    ui_print "- 标准模式：开机自动加载"
    return 0 2>/dev/null || exit 0
fi

ui_print "**********************************************"
ui_print "  检测到越狱(late-load)模式"
ui_print "  模块将自动捕获电量计设备指针"
ui_print "  关机电压由 hook 即时强制"
ui_print "**********************************************"

return 0 2>/dev/null || exit 0
