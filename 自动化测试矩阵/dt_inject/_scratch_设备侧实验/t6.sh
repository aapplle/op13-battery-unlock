#!/system/bin/sh
echo "== STEP6 SNAPSHOT (after all tests) =="
echo "--- backup dir: md5 + size + mtime per file ---"
for f in /data/adb/uv2800_backup/*; do
  [ -f "$f" ] || continue
  printf 'BKFILE|%s|md5=%s|size=%s|mtime=%s\n' "$(basename $f)" "$(md5sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f")" "$(ls -l "$f" | awk '{print $6,$7,$8}')"
done
echo "--- backup dir entries (incl. dirs) ---"
ls -la /data/adb/uv2800_backup/
echo "--- module dir (skip/disable check) ---"
ls -la /data/adb/modules/uv2800/
echo "--- lsmod / proc/modules ---"
lsmod | grep uv2800
grep uv2800 /proc/modules
echo "--- uv2800 sysfs params (read-only inspection) ---"
for p in /sys/module/uv2800/parameters/*; do
  printf 'PARAM|%s|%s\n' "$(basename $p)" "$(cat "$p" 2>/dev/null)"
done
echo "--- dmesg uv2800 lines (insmod/rmmod evidence) ---"
dmesg 2>/dev/null | grep -i uv2800 | tail -12
echo "--- real log now ---"
wc -l /data/adb/uv2800_backup/uv2800.log
md5sum /data/adb/uv2800_backup/uv2800.log
echo "--- DT tree mtimes (read-only fs, must be untouched) ---"
ls -la /sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy/
echo "--- DT 24 tables md5 (compare against t1b capture) ---"
for rr in strategy_ratio_range_min strategy_ratio_range_low strategy_ratio_range_mid_low strategy_ratio_range_mid strategy_ratio_range_mid_high strategy_ratio_range_high; do
  for tt in strategy_temp_cold strategy_temp_cool strategy_temp_normal strategy_temp_warm; do
    printf 'TBLMD5|%s/%s|%s\n' "$rr" "$tt" "$(md5sum "/sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy/$rr/$tt" | cut -d' ' -f1)"
  done
done
echo "--- DT range attrs md5 ---"
md5sum /sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy/oplus,ratio_range /sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy/oplus,temp_range
echo "--- /data/local/tmp test artifacts present ---"
ls -la /data/local/tmp/ | grep -E 'uvdt|uv_log.sh|t[0-9]|uvv6|probe|recon|\.uv_' 
echo "== STEP6 END =="
