#!/system/bin/sh
P=/sys/module/uv2800/parameters; B=/data/adb/uv2800_backup
C=/sys/class/oplus_chg/battery; V=$C/vbat_uv
echo 1 > $P/adsp_read 2>/dev/null
echo "mod=$(lsmod | grep -c ^uv2800)"
echo "vbat=$(cat $V 2>/dev/null)"
echo "tgt=$(cat $P/uv_target_mv 2>/dev/null)"
echo "adsp=$(cat $P/adsp_read 2>/dev/null)"
echo "adspmv=$(cat $P/uv_adsp_mv 2>/dev/null)"
echo "resume=$(cat $P/resume 2>/dev/null)"
echo "skip=$([ -f $B/skip ] && echo yes || echo no)"
echo "nrs=$([ -f $B/no_real_soc ] && echo yes || echo no)"
echo "naw=$([ -f $B/no_adsp_write ] && echo yes || echo no)"
echo "orig=$(cat $B/adsp_orig.txt 2>/dev/null)"
echo "origbad=$(cat $B/adsp_orig.bad 2>/dev/null)"
echo "adspst=$(cat $B/adsp_state 2>/dev/null)"
echo "tfile=$(cat $B/target_mv 2>/dev/null)"
echo "bind=$(grep -c chip_soc /proc/self/mountinfo)"
echo "xml=$([ -f /data/system/oplus_devicepolicy_data_customize.xml ] && echo yes || echo no)"
echo "origstate=$(cat $B/orig_state 2>/dev/null)"
echo "applied=$([ -f $B/applied ] && echo yes || echo no)"