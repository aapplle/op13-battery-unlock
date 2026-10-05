
. /data/local/tmp/uv_log.sh
TLOG=/data/local/tmp/uvv6_test.log
RLOG=/data/adb/uv2800_backup/uv2800.log
lstat() {
  _l=$(wc -l < "$1" 2>/dev/null)
  case "$_l" in ''|*[!0-9]*) _l=0 ;; esac
  _m=$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)
  case "$_m" in '') _m=NONE ;; esac
  echo "$_l $_m"
}

echo "== STEP3 START (service.sh:44 shape; stderr really dropped) =="
: > "$TLOG"
S3() {
  _n="$1"; _setup="$2"; _red="$3"
  set -- $(lstat "$TLOG"); _bl=$1
  _res=$( ( eval "$_setup"; _dt=$( eval "uv_dt_orig $_red" ); _rc=$?; printf 'dt=[%s] rc=%s' "$_dt" "$_rc" ) 2>/data/local/tmp/.uv_e3 )
  _e3=$(cat /data/local/tmp/.uv_e3 2>/dev/null | tr '\n' '~')
  set -- $(lstat "$TLOG"); _al=$1
  _nl=""
  if [ "$_al" -gt "$_bl" ]; then _nl=$(tail -n +$((_bl+1)) "$TLOG" 2>/dev/null | tr '\n' '~'); fi
  printf 'S3|%s|%s|outer_stderr=[%s]|lb=%s|la=%s|new=[%s]\n' "$_n" "$_res" "$_e3" "$_bl" "$_al" "$_nl"
}
FAKE="UV_T_DTB=/data/local/tmp/uvdt"
IN="UV_T_BATT=silicon_p_770; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400"
echo "-- (a) service.sh:44 shape: uv_dt_orig 2>/dev/null --"
S3 "a1_node_mismatch_2devnull" "UV_LOG=$TLOG; UV_T_BATT=aaa_no_such" "2>/dev/null"
S3 "a2_table48B_2devnull"      "UV_LOG=$TLOG; $FAKE/t48; $IN" "2>/dev/null"
S3 "a3_result_oob_2devnull"    "UV_LOG=$TLOG; $FAKE/v2500; $IN" "2>/dev/null"
S3 "a4_rr_missing_2devnull"    "UV_LOG=$TLOG; $FAKE/rr_missing; $IN" "2>/dev/null"
S3 "a5_counts_nan_2devnull"    "UV_LOG=$TLOG; UV_T_CNT=abc; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400" "2>/dev/null"
echo "-- (b) identical cases WITHOUT redirect (stderr visible, control) --"
S3 "b1_node_mismatch_visible" "UV_LOG=$TLOG; UV_T_BATT=aaa_no_such" ""
S3 "b2_table48B_visible"      "UV_LOG=$TLOG; $FAKE/t48; $IN" ""
echo "-- (c) success under 2>/dev/null must add nothing --"
S3 "c1_success_2devnull"      "UV_LOG=$TLOG; UV_T_BATT=silicon_p_770" "2>/dev/null"
echo "-- raw test log --"
_i=0
while IFS= read -r _line; do _i=$((_i+1)); printf 'RAW|%d|%s\n' "$_i" "$_line"; done < "$TLOG"
echo "== STEP3 END =="
