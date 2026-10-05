
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

echo "== STEP1 START =="
set -- $(lstat "$RLOG"); echo "PRE|lines=$1|md5=$2"
ls -la "$RLOG"
echo "-- A. default call (real sysfs inputs, no UV_DT_DEBUG) --"
RC "$RLOG" "A_default" 'uv_dt_orig'
echo "-- B. 24 real tables sweep (scored pass, real log) --"
for r in 0 1 2 3 4 5; do
  case $r in
    0) cnt=1000 ;; 1) cnt=2500 ;; 2) cnt=4000 ;;
    3) cnt=6000 ;; 4) cnt=8000 ;; 5) cnt=10000 ;;
  esac
  for t in 0 1 2 3; do
    case $t in
      0) tv=-60 ;; 1) tv=0 ;; 2) tv=200 ;; 3) tv=400 ;;
    esac
    RC "$RLOG" "SW_r$r-t$t" "UV_T_CNT=$cnt; UV_T_CC=1000; UV_T_CALI=0; UV_T_TEMP=$tv; uv_dt_orig"
  done
done
set -- $(lstat "$RLOG"); echo "POST|lines=$1|md5=$2"
ls -la "$RLOG"
echo "== STEP1 END =="
