#!/system/bin/sh
echo "== FINAL: sh -n on device mksh (before cleanup) =="
sh -n /data/local/tmp/uv_log.sh && echo "device sh -n log.sh: OK" || echo "device sh -n log.sh: FAIL"
md5sum /data/local/tmp/uv_log.sh
echo "== FINAL: uptime vs last uv2800 dmesg (prove no insmod/rmmod during tests) =="
echo "uptime_now=[$(cat /proc/uptime | cut -d' ' -f1)] s"
dmesg 2>/dev/null | grep -i uv2800 | tail -3
echo "== CLEANUP /data/local/tmp artifacts =="
BASE=/data/local/tmp
ARTS="$BASE/uv_log.sh $BASE/uvdt $BASE/t1.sh $BASE/t1b.sh $BASE/t2.sh $BASE/t3.sh $BASE/t4.sh $BASE/t5.sh $BASE/t6.sh $BASE/probe.sh $BASE/recon.sh $BASE/recon2.sh $BASE/uvv6_test.log $BASE/.uv_e $BASE/.uv_e3 $BASE/.uv_e4 $BASE/.uv_e5 $BASE/.uv_new4 $BASE/.uv_head $BASE/.uv_head4"
for p in $ARTS; do
  case "$p" in
    /data/local/tmp/*) : ;;
    *) echo "SAFETY_ABORT: $p not under /data/local/tmp"; exit 1 ;;
  esac
done
echo "-- will remove exactly: --"
for p in $ARTS; do [ -e "$p" ] && ls -d "$p"; done
for p in $ARTS; do [ -e "$p" ] && rm -rf "$p"; done
echo "-- after cleanup, remaining test artifacts (expect none): --"
ls -la "$BASE" | grep -E 'uvdt|uv_log.sh|/t[0-9]|uvv6|probe|recon2?\.sh|\.uv_' || echo "(none)"
echo "-- /data/local/tmp still contains pre-existing files (untouched): --"
ls "$BASE" | head -40
echo "== FINAL backup/module state =="
ls -la /data/adb/uv2800_backup/
wc -l /data/adb/uv2800_backup/uv2800.log
md5sum /data/adb/uv2800_backup/uv2800.log
ls /data/adb/modules/uv2800/
echo "== DONE =="
