
. /data/local/tmp/uv_log.sh
RLOG=/data/adb/uv2800_backup/uv2800.log

echo "== STEP4 START (REAL UV_LOG, exactly ONE trigger) =="
echo "UV_LOG from sourced log.sh = [$UV_LOG]"
ls -la "$RLOG"
BL=$(wc -l < "$RLOG"); BM=$(md5sum "$RLOG" | cut -d' ' -f1)
echo "BEFORE|lines=$BL|md5=$BM"
echo "-- ONE trigger: UV_T_CNT=abc, no UV_LOG override --"
_o=$( UV_T_CNT=abc; uv_dt_orig 2>/data/local/tmp/.uv_e4 )
rc=$?
echo "stdout=[$_o] rc=$rc"
echo "stderr_line=[$(cat /data/local/tmp/.uv_e4 | tr '\n' '~')]"
AL=$(wc -l < "$RLOG"); AM=$(md5sum "$RLOG" | cut -d' ' -f1)
echo "AFTER|lines=$AL|md5=$AM"
echo "DELTA_LINES=$((AL-BL))"
tail -n +$((BL+1)) "$RLOG" | while IFS= read -r _line; do printf 'NEW|[%s]\n' "$_line"; done
NEWN=$((AL-BL))
echo "-- restore (only if exactly 1 new line and it is a uv_dt_orig FAIL line) --"
if [ "$NEWN" = 1 ]; then
  if tail -n 1 "$RLOG" | grep -q 'uv2800: \[uv_dt_orig\] FAIL'; then
    head -n "$BL" "$RLOG" > /data/local/tmp/.uv_head4
    cat /data/local/tmp/.uv_head4 > "$RLOG"
    rm -f /data/local/tmp/.uv_head4
    RL=$(wc -l < "$RLOG"); RM=$(md5sum "$RLOG" | cut -d' ' -f1)
    echo "RESTORED|lines=$RL|md5=$RM|baseline_md5=$BM|match=$([ "$RM" = "$BM" ] && echo YES || echo NO)"
  else
    echo "RESTORE_SKIPPED: last line is not a uv_dt_orig FAIL line"
  fi
else
  echo "RESTORE_SKIPPED: NEWN=$NEWN"
fi
ls -la "$RLOG"
echo "== STEP4 END =="
