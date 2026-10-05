#!/system/bin/sh
. /data/local/tmp/uv_log.sh
TLOG=/data/local/tmp/uvv6_test.log
EO=/data/local/tmp/.uv_ee
lstat() { _l=$(wc -l < "$1" 2>/dev/null); case "$_l" in ''|*[!0-9]*) _l=0 ;; esac; echo "$_l"; }
strip() { printf '%s\n' "$1" | sed 's/^.*\] uv2800: //'; }
CK() {
  _n="$1"; _snip="$2"
  _bl=$(lstat "$TLOG")
  _o=$( ( eval "$_snip" ) 2>"$EO" ); _rc=$?
  _e=$(cat "$EO")
  _al=$(lstat "$TLOG")
  _nl=$(tail -n 1 "$TLOG")
  _body=$(strip "$_nl")
  if [ "$_body" = "$_e" ] && [ -n "$_e" ]; then _m=YES; else _m=NO; fi
  case "$_nl" in
    \[[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]\ uv2800:\ *) _ts=OK ;;
    *) _ts=BAD ;;
  esac
  case "$_o" in '') _oe=YES ;; *) _oe=NO ;; esac
  printf 'CK|%s|rc=%s|stdout_empty=%s|ts_prefix=%s|stderr_eq_log=%s|dlog=%s\n' \
     "$_n" "$_rc" "$_oe" "$_ts" "$_m" "$((_al-_bl))"
}
: > "$TLOG"
FAKE="UV_T_DTB=/data/local/tmp/uvdt"
IN="UV_T_BATT=silicon_p_770; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400"
CK "01_node_mismatch"   "UV_LOG=$TLOG; UV_T_BATT=aaa_no_such; uv_dt_orig"
CK "02_subtree_missing" "UV_LOG=$TLOG; UV_T_BATT=; UV_T_DTB=/data/local/tmp/uvdt/empty; uv_dt_orig"
CK "03_counts_nan"      "UV_LOG=$TLOG; UV_T_CNT=abc; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
CK "04_cali_invalid"    "UV_LOG=$TLOG; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=xyz; UV_T_TEMP=400; uv_dt_orig"
CK "05_len_gate"        "UV_LOG=$TLOG; UV_T_CNT=1234567890; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
CK "06_upper_bound"     "UV_LOG=$TLOG; UV_T_CNT=1000001; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
CK "07_cnt_cc_zero"     "UV_LOG=$TLOG; UV_T_CNT=0; UV_T_CC=0; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
CK "08_rr_missing"      "UV_LOG=$TLOG; $FAKE/rr_missing; $IN; uv_dt_orig"
CK "09_rr_4items"       "UV_LOG=$TLOG; $FAKE/rr4; $IN; uv_dt_orig"
CK "10_tr_2items"       "UV_LOG=$TLOG; $FAKE/tr2; $IN; uv_dt_orig"
CK "11_table_48B"       "UV_LOG=$TLOG; $FAKE/t48; $IN; uv_dt_orig"
CK "12_f0_base"         "UV_LOG=$TLOG; $FAKE/f0base; $IN; uv_dt_orig"
CK "13_f0_order"        "UV_LOG=$TLOG; $FAKE/f0order; $IN; uv_dt_orig"
CK "14_result_oob_2500" "UV_LOG=$TLOG; $FAKE/v2500; $IN; uv_dt_orig"
CK "15_table_65B"       "UV_LOG=$TLOG; $FAKE/b65; $IN; uv_dt_orig"
echo "-- 2>/dev/null call-site shape (stderr dropped) --"
CK2() {
  _n="$1"; _setup="$2"
  _bl=$(lstat "$TLOG")
  _res=$( ( eval "$_setup"; _dt=$( eval "uv_dt_orig 2>/dev/null" ); _rc=$?; printf 'dt=[%s]rc=%s' "$_dt" "$_rc" ) 2>/dev/null )
  _al=$(lstat "$TLOG")
  _nl=$(tail -n 1 "$TLOG")
  _body=$(strip "$_nl")
  case "$_nl" in
    \[[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]\ uv2800:\ *) _ts=OK ;;
    *) _ts=BAD ;;
  esac
  printf 'CK2|%s|%s|ts_prefix=%s|log_grew=%s|log_reason=[%s]\n' "$_n" "$_res" "$_ts" "$((_al-_bl))" "$_body"
}
CK2 "devnull_node_mismatch" "UV_LOG=$TLOG; UV_T_BATT=aaa_no_such"
CK2 "devnull_counts_nan"    "UV_LOG=$TLOG; UV_T_CNT=abc; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400"
echo "-- success must not write --"
CK "16_success_silicon770"  "UV_LOG=$TLOG; UV_T_BATT=silicon_p_770; uv_dt_orig"
echo "TOTAL_LOG_LINES=$(lstat $TLOG)"
