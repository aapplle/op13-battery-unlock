
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
  printf 'CASE|%s|rc=%s|out=[%s]|err=[%s]|lb=%s|la=%s|new=[%s]\n' \
     "$_n" "$_rc" "$_o" "$_e" "$_bl" "$_al" "$_nl"
}
rawdump() {
  _i=0
  while IFS= read -r _line; do
    _i=$((_i+1))
    printf 'RAW|%d|%s\n' "$_i" "$_line"
  done < "$1"
}

echo "== STEP2 START (UV_LOG -> test log) =="
: > "$TLOG"
echo "-- control: valid fake tree --"
RC "$TLOG" "C0_valid_fake" "UV_LOG=$TLOG; UV_T_DTB=/data/local/tmp/uvdt/valid; UV_T_BATT=silicon_p_770; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
echo "-- 11 failure branches --"
RC "$TLOG" "F01_node_mismatch" "UV_LOG=$TLOG; UV_T_BATT=aaa_no_such; uv_dt_orig"
RC "$TLOG" "F02_subtree_missing" "UV_LOG=$TLOG; UV_T_BATT=; UV_T_DTB=/data/local/tmp/uvdt/empty; uv_dt_orig"
RC "$TLOG" "F03_counts_nan" "UV_LOG=$TLOG; UV_T_CNT=abc; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
RC "$TLOG" "F04_cali_invalid" "UV_LOG=$TLOG; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=xyz; UV_T_TEMP=400; uv_dt_orig"
RC "$TLOG" "F05_len_gate" "UV_LOG=$TLOG; UV_T_CNT=1234567890; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
RC "$TLOG" "F06_upper_bound" "UV_LOG=$TLOG; UV_T_CNT=1000001; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
RC "$TLOG" "F07_cnt_cc_zero" "UV_LOG=$TLOG; UV_T_CNT=0; UV_T_CC=0; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
FAKE="UV_T_DTB=/data/local/tmp/uvdt"
IN="UV_T_BATT=silicon_p_770; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400"
RC "$TLOG" "F08_rr_count4"   "UV_LOG=$TLOG; $FAKE/rr4; $IN; uv_dt_orig"
RC "$TLOG" "F09_tr_count2"   "UV_LOG=$TLOG; $FAKE/tr2; $IN; uv_dt_orig"
RC "$TLOG" "F10_table_48B"   "UV_LOG=$TLOG; $FAKE/t48; $IN; uv_dt_orig"
RC "$TLOG" "F11_result_oob"  "UV_LOG=$TLOG; $FAKE/v2500; $IN; uv_dt_orig"
echo "-- raw test log dump --"
rawdump "$TLOG"
echo "== STEP2 END =="
