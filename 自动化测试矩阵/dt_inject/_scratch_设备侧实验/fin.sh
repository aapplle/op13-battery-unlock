#!/system/bin/sh
echo "== remove my last two helper scripts =="
for p in /data/local/tmp/fix4.sh /data/local/tmp/clean.sh; do
  case "$p" in /data/local/tmp/*) rm -f "$p"; echo "removed $p" ;; esac
done
echo "== confirm none of my artifacts remain =="
ls -la /data/local/tmp/ | grep -E 'uvdt|uv_log\.sh|t[1-6]\.sh|t1b\.sh|uvv6|probe\.sh|recon2?\.sh|clean\.sh|fix4\.sh|\.uv_' || echo "(none of mine remain)"
echo "== pre-existing dirs mtimes (not created by me) =="
ls -ld /data/local/tmp/uvtest /data/local/tmp/uvtest.sh /data/local/tmp/ddrc /data/local/tmp/raw 2>/dev/null
echo "== FINAL STATE =="
wc -l /data/adb/uv2800_backup/uv2800.log
md5sum /data/adb/uv2800_backup/uv2800.log
for f in /data/adb/uv2800_backup/*; do [ -f "$f" ] && printf '%s %s\n' "$(md5sum "$f" | cut -d' ' -f1)" "$(basename $f)"; done
ls /data/adb/modules/uv2800/
lsmod | grep uv2800
