#!/system/bin/sh
echo "=== shell id ==="
echo "sh=$0"
echo "=== push check ==="
ls -la /data/local/tmp/uv_log.sh
md5sum /data/local/tmp/uv_log.sh
echo "=== dt trees ==="
ls /data/local/tmp/uvdt/
echo "=== temp-assign semantics ==="
f() { echo "inside UV_LOG=[$UV_LOG]"; }
UV_LOG=/data/local/tmp/uvv6_test.log; echo "assign-then-call: $(UV_LOG=/tmp/x; f)"
( UV_LOG=/data/local/tmp/uvv6_test.log; f )
UV_LOG=orig; f
echo "=== tools ==="
for t in od awk cut tr md5sum wc tail date sleep lsmod; do command -v $t >/dev/null 2>&1 && echo "OK $t" || echo "MISSING $t"; done
echo "=== log now ==="
wc -l /data/adb/uv2800_backup/uv2800.log
md5sum /data/adb/uv2800_backup/uv2800.log
