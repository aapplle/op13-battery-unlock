
. /data/local/tmp/uv_log.sh
TLOG=/data/local/tmp/uvv6_test.log
EO=/data/local/tmp/.uv_e
RLOG=/data/adb/uv2800_backup/uv2800.log

lstat() {
  _l=$(wc -l < "$1" 2>/dev/null)
  case "$_l" in ''|*[!0-9]*) _l=0 ;; esac
  _m=$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)
  case "$_m" in '') _m=NONE ;; esac
  echo "$_l $_m"
}
RC() {
  _logf="$1"; _n="$2"; _snip="$3"
  set -- $(lstat "$_logf"); _bl=$1; _bm=$2
  _o=$( ( eval "$_snip" ) 2>"$EO" ); _rc=$?
  _e=$(cat "$EO" 2>/dev/null | tr '\n' '~')
  set -- $(lstat "$_logf"); _al=$1; _am=$2
  _nl=""
  if [ "$_al" -gt "$_bl" ]; then _nl=$(tail -n +$((_bl+1)) "$_logf" 2>/dev/null | tr '\n' '~'); fi
  printf 'CASE|%s|rc=%s|out=[%s]|err=[%s]|lb=%s|la=%s|mb=%s|ma=%s|new=[%s]\n' \
     "$_n" "$_rc" "$_o" "$_e" "$_bl" "$_al" "$_bm" "$_am" "$_nl"
}

echo "== STEP1B START (aux: which table each combo hits; UV_LOG->test log, debug on) =="
: > "$TLOG"
for r in 0 1 2 3 4 5; do
  case $r in
    0) cnt=1000 ;; 1) cnt=2500 ;; 2) cnt=4000 ;;
    3) cnt=6000 ;; 4) cnt=8000 ;; 5) cnt=10000 ;;
  esac
  for t in 0 1 2 3; do
    case $t in
      0) tv=-60 ;; 1) tv=0 ;; 2) tv=200 ;; 3) tv=400 ;;
    esac
    RC "$TLOG" "DBG_r$r-t$t" "UV_LOG=$TLOG; UV_DT_DEBUG=1; UV_T_CNT=$cnt; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=$tv; uv_dt_orig"
  done
done
echo "-- real tables present --"
DTB=/sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy
for rr in strategy_ratio_range_min strategy_ratio_range_low strategy_ratio_range_mid_low strategy_ratio_range_mid strategy_ratio_range_mid_high strategy_ratio_range_high; do
  for tt in strategy_temp_cold strategy_temp_cool strategy_temp_normal strategy_temp_warm; do
    if [ -f "$DTB/$rr/$tt" ]; then
      printf 'TBL|%s/%s|size=%s|md5=%s\n' "$rr" "$tt" "$(wc -c < "$DTB/$rr/$tt")" "$(md5sum "$DTB/$rr/$tt" | cut -d' ' -f1)"
    fi
  done
done
echo "== STEP1B END =="
