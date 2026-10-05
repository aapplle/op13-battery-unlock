#!/system/bin/sh
P=/sys/module/uv2800/parameters
BK=/data/adb/uv2800_backup
echo "模块已加载 : $(lsmod | grep -c "^uv2800")"
echo "skip 文件  : $([ -f $BK/skip ] && echo 有 || echo 无)"
echo "uv_target_mv: $(cat $P/uv_target_mv 2>/dev/null || echo "(无此参数)")"
echo "vbat_uv    : $(cat /sys/class/oplus_chg/battery/vbat_uv)   ← 当前关机截止电压"
echo "resume     : $(cat $P/resume 2>/dev/null || echo "(无)")"
echo "adsp_read  : $(echo 1 > $P/adsp_read 2>/dev/null; cat $P/adsp_read 2>/dev/null || echo "(无)")"
echo "adsp_orig  : $(cat $BK/adsp_orig.txt 2>/dev/null)"
echo "target_mv  : $(cat $BK/target_mv 2>/dev/null)"
echo "bind 层数  : $(grep -c chip_soc /proc/self/mountinfo)"
echo "capacity   : $(cat /sys/class/power_supply/battery/capacity)  chip_soc: $(cat /sys/class/oplus_chg/battery/chip_soc)"
echo "模块目录   : $([ -f /data/adb/modules/uv2800/module.prop ] && grep ^version= /data/adb/modules/uv2800/module.prop || echo "未安装")"
echo "--- 日志尾部 ---"
tail -8 $BK/uv2800.log 2>/dev/null