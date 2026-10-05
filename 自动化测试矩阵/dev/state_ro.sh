#!/system/bin/sh
# 纯只读状态检查（不写 adsp_read，避免任何写入）
BK=/data/adb/uv2800_backup
echo "模块已加载   : $(lsmod | grep -c ^uv2800)"
echo "模块目录     : $([ -f /data/adb/modules/uv2800/module.prop ] && grep ^version= /data/adb/modules/uv2800/module.prop || echo 未安装)"
echo "modules_update: $(ls /data/adb/modules_update/ 2>/dev/null | tr "\n" " ")"
echo "vbat_uv      : $(cat /sys/class/oplus_chg/battery/vbat_uv)   ← 关键"
echo "skip 文件    : $([ -f $BK/skip ] && echo 有 || echo 无)"
echo "adsp_orig.txt: $(cat $BK/adsp_orig.txt 2>/dev/null)"
echo "adsp_orig.bad: $(cat $BK/adsp_orig.bad 2>/dev/null)"
echo "adsp_state   : $(cat $BK/adsp_state 2>/dev/null)"
echo "target_mv    : $(cat $BK/target_mv 2>/dev/null)"
echo "bind 层数    : $(grep -c chip_soc /proc/self/mountinfo)"
echo "capacity/soc : $(cat /sys/class/power_supply/battery/capacity) / $(cat /sys/class/oplus_chg/battery/chip_soc)"
echo "uv2800 相关文件: $(ls $BK/ 2>/dev/null | tr "\n" " ")"
echo "--- dmesg 里 uv2800 最近 6 条 ---"
dmesg 2>/dev/null | grep "uv2800:" | tail -6