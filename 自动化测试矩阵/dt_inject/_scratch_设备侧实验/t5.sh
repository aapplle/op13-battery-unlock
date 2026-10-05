
. /data/local/tmp/uv_log.sh
TLOG=/data/local/tmp/uvv6_test.log
EO=/data/local/tmp/.uv_e
lstat() {
  _l=$(wc -l < "$1" 2>/dev/null)
  case "$_l" in ''|*[!0-9]*) _l=0 ;; esac
  _m=$(md5sum "$1" 2>/dev/null | cut -d' ' -f1)
  case "$_m" in '') _m=NONE ;; esac
  echo "$_l $_m"
}
RC() {
  _logf="$1"; _n="$2"; _snip="$3"
  set -- $(lstat "$_logf"); _bl=$1
  _o=$( ( eval "$_snip" ) 2>"$EO" ); _rc=$?
  _e=$(cat "$EO" 2>/dev/null | tr '\n' '~')
  set -- $(lstat "$_logf"); _al=$1
  printf 'CASE|%s|rc=%s|out=[%s]|err=[%s]|dlog=%s\n' "$_n" "$_rc" "$_o" "$_e" "$((_al-_bl))"
}

echo "== STEP5 START (regression; all failures -> test log, successes must not write) =="
: > "$TLOG"
FAKE="UV_T_DTB=/data/local/tmp/uvdt"
IN="UV_T_BATT=silicon_p_770; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=400"
echo "--- 12 safety-failure regressions (expect out empty / rc=1 / dlog=1) ---"
RC "$TLOG" "R01_rr_missing"    "UV_LOG=$TLOG; $FAKE/rr_missing; $IN; uv_dt_orig"
RC "$TLOG" "R02_rr_4items"     "UV_LOG=$TLOG; $FAKE/rr4; $IN; uv_dt_orig"
RC "$TLOG" "R03_tr_2items"     "UV_LOG=$TLOG; $FAKE/tr2; $IN; uv_dt_orig"
RC "$TLOG" "R04_table_48B"     "UV_LOG=$TLOG; $FAKE/t48; $IN; uv_dt_orig"
RC "$TLOG" "R05_f0_base"       "UV_LOG=$TLOG; $FAKE/f0base; $IN; uv_dt_orig"
RC "$TLOG" "R06_f0_order"      "UV_LOG=$TLOG; $FAKE/f0order; $IN; uv_dt_orig"
RC "$TLOG" "R07_row_v1_2500"   "UV_LOG=$TLOG; $FAKE/v2500; $IN; uv_dt_orig"
RC "$TLOG" "R08_table_65B"     "UV_LOG=$TLOG; $FAKE/b65; $IN; uv_dt_orig"
RC "$TLOG" "R09_subtree_absent" "UV_LOG=$TLOG; UV_T_BATT=; UV_T_DTB=/data/local/tmp/uvdt/empty; uv_dt_orig"
RC "$TLOG" "R10_cnt_cc_zero"   "UV_LOG=$TLOG; UV_T_CNT=0; UV_T_CC=0; UV_T_CALI=0; UV_T_TEMP=400; uv_dt_orig"
RC "$TLOG" "R11_batt_no_such"  "UV_LOG=$TLOG; UV_T_BATT=aaa_no_such; uv_dt_orig"
RC "$TLOG" "R12_cali_invalid"  "UV_LOG=$TLOG; UV_T_CNT=100000; UV_T_CC=1000; UV_T_CALI=xyz; UV_T_TEMP=400; uv_dt_orig"
echo "--- success paths (expect rc=0, stderr empty, dlog=0) ---"
RC "$TLOG" "S01_batt_silicon770_default" "UV_LOG=$TLOG; UV_T_BATT=silicon_p_770; uv_dt_orig"
RC "$TLOG" "S02_CNT_1e6"      "UV_LOG=$TLOG; UV_T_CNT=1000000; uv_dt_orig"
RC "$TLOG" "S03_CC_1e6"       "UV_LOG=$TLOG; UV_T_CC=1000000; uv_dt_orig"
RC "$TLOG" "S04_CALI_1e4"     "UV_LOG=$TLOG; UV_T_CALI=10000; uv_dt_orig"
RC "$TLOG" "S05_CALI_500"     "UV_LOG=$TLOG; UV_T_CALI=500; uv_dt_orig"
RC "$TLOG" "S06_real_64B_table" "UV_LOG=$TLOG; uv_dt_orig"
RC "$TLOG" "S07_fake_valid_table" "UV_LOG=$TLOG; $FAKE/valid; $IN; uv_dt_orig"
echo "--- same-shell consecutive: normal -> fail -> normal -> fail -> normal ---"
UV_LOG=$TLOG
o1=$(uv_dt_orig); r1=$?
o2=$(UV_T_CNT=abc; uv_dt_orig); r2=$?
o3=$(uv_dt_orig); r3=$?
o4=$(UV_T_CNT=abc; uv_dt_orig); r4=$?
o5=$(uv_dt_orig); r5=$?
echo "SEQ|1=[$o1]rc=$r1|2=[$o2]rc=$r2|3=[$o3]rc=$r3|4=[$o4]rc=$r4|5=[$o5]rc=$r5"
echo "SEQ_EXPECT|3250/empty/3250/empty/3250 rc=0/1/0/1/0"
echo "--- table dumps used by threshold cases ---"
DTB=/sys/firmware/devicetree/base/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy
for f in "$DTB/strategy_ratio_range_mid/strategy_temp_normal" "$DTB/strategy_ratio_range_high/strategy_temp_normal"; do
  echo "TBLFILE|$f|size=$(wc -c < "$f")"
  od -An -tx1 -v "$f"
done
echo "-- test log total lines --"
wc -l < "$TLOG"
echo "== STEP5 END =="
