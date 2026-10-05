#!/system/bin/sh
DTB=/sys/firmware/devicetree/base/soc/oplus,mms_gauge
echo "=== DT root ==="
ls -la "$DTB"
echo "=== nodes ==="
for d in "$DTB"/*/; do echo "NODE[$d] HAS_DDRC=$([ -d "${d}ddrc_strategy" ] && echo yes || echo no)"; done
echo "=== ddrc subtree ==="
ls -la "$DTB/silicon_p_770/ddrc_strategy/" 2>&1
echo "=== ratio_range hex ==="
od -An -tx1 -v "$DTB/silicon_p_770/ddrc_strategy/oplus,ratio_range" 2>&1
echo "=== temp_range hex ==="
od -An -tx1 -v "$DTB/silicon_p_770/ddrc_strategy/oplus,temp_range" 2>&1
echo "=== log baseline ==="
wc -l /data/adb/uv2800_backup/uv2800.log 2>&1
md5sum /data/adb/uv2800_backup/uv2800.log 2>&1
echo "=== backup dir ==="
ls -la /data/adb/uv2800_backup/ 2>&1
echo "=== module list ==="
ls -la /data/adb/modules/ 2>&1
echo "=== lsmod uv2800 ==="
lsmod 2>/dev/null | grep -i uv2800 || echo "no uv2800 in lsmod"
echo "=== /data/local/tmp ==="
ls -la /data/local/tmp/ 2>&1 | head -30
