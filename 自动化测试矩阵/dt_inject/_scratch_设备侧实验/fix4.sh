
. /data/local/tmp/uv_log.sh
RLOG=/data/adb/uv2800_backup/uv2800.log
BASE_MD5=de93afcbe8f5c3f96bec7624775a265a
BASE_N=514
echo "== CLEANUP: drop the 2 lines my step-4 harness added =="
set -- $(wc -l < "$RLOG") ; CUR=$1
echo "current_lines=$CUR md5=$(md5sum "$RLOG" | cut -d' ' -f1)"
echo "-- the 2 added lines were: --"
tail -n 2 "$RLOG"
# drop exactly the last 2 lines, then prove the first 514 lines equal the original byte-for-byte
head -n "$BASE_N" "$RLOG" > /data/local/tmp/.uv_head
cat /data/local/tmp/.uv_head > "$RLOG"
rm -f /data/local/tmp/.uv_head
NL=$(wc -l < "$RLOG"); NM=$(md5sum "$RLOG" | cut -d' ' -f1)
echo "after_truncate|lines=$NL|md5=$NM"
if [ "$NM" = "$BASE_MD5" ] && [ "$NL" = "$BASE_N" ]; then
  echo "CLEANUP_OK: first 514 lines are byte-identical to the original (md5 matches baseline)"
else
  echo "CLEANUP_FAIL"
fi
ls -la "$RLOG"
