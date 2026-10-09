#!/system/bin/sh
# 在临时目录映射绝对路径，执行真实 action.sh 的提前退出分支；不接触设备状态。
# 用法：sh test-action.sh /path/to/module/source
# 【v10.8 研究存档】依赖 v10.8 的 restore-target.sh 与 parameters/restore；
# v11 的 action.sh 已改为 restore.sh 共享事务 + resume 参数，本测试不再适用。
set -eu
SRC=$1
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
MOD="$TESTDIR/module"
BK="$TESTDIR/backup"
P="$TESTDIR/parameters"
V="$TESTDIR/votes/TARGET_TERM_VOLTAGE"
mkdir -p "$MOD" "$BK" "$P" "$V"
sed -e "s|/sys/module/uv2800/parameters|$P|g" \
    -e "s|/sys/class/oplus_chg/battery/vbat_uv|$TESTDIR/vbat|g" \
    -e "s|/sys/class/power_supply/battery/voltage_now|$TESTDIR/voltage|g" \
    -e "s|/data/adb/uv2800_backup|$BK|g" \
    "$SRC/action.sh" > "$MOD/action.sh"
sed "s|/proc/oplus-votable|$TESTDIR/votes|g" "$SRC/restore-target.sh" > "$MOD/restore-target.sh"
echo 4400000 > "$TESTDIR/voltage"
echo 2800 > "$TESTDIR/vbat"
echo 3000 > "$BK/adsp_orig.txt"
echo old-state > "$P/restore"
echo 2600 > "$P/adsp_read"
echo 0 > "$V/force_active"
cat > "$V/status" <<EOF
TARGET_TERM_VOLTAGE: DEEP_COUNT_VOTER: en=1 v=3100
TARGET_TERM_VOLTAGE: effective=DEEP_COUNT_VOTER type=Max v=3100
EOF
export KSU_LATE_LOAD=0
UV2800_DRYRUN=1 sh "$MOD/action.sh" > "$TESTDIR/output"
grep -q '3100 mV' "$TESTDIR/output"
[ "$(cat "$P/restore")" = old-state ]
[ "$(cat "$P/adsp_read")" = 2600 ]
[ "$(cat "$BK/adsp_orig.txt")" = 3000 ]
[ ! -e "$BK/skip" ]
[ "$(ls -A "$BK" | wc -l)" -eq 1 ]
echo 'PASS dryrun_3100_preserves_all_state'

must_fail() {
    if UV2800_DRYRUN=0 sh "$MOD/action.sh" > "$TESTDIR/output" 2>&1; then
        echo "FAIL $1: action succeeded"; exit 1
    fi
    if grep -q '回写完成！' "$TESTDIR/output"; then
        echo "FAIL $1: reported success"; exit 1
    fi
    [ "$(cat "$BK/adsp_orig.txt")" = 3000 ]
    echo "PASS $1"
}
echo 1 > "$V/force_active"
must_fail forced_vote_does_not_restore
[ ! -e "$BK/skip" ]
[ "$(cat "$P/restore")" = old-state ]
echo 0 > "$V/force_active"
mv "$V/status" "$V/saved"
must_fail missing_vote_does_not_use_backup
[ ! -e "$BK/skip" ]
[ "$(cat "$P/restore")" = old-state ]
mv "$V/saved" "$V/status"

# /dev/null 是普通字符设备；当它被当作 backup 目录时 mkdir 必然失败。
sed "s|BK=$BK|BK=/dev/null|" "$MOD/action.sh" > "$MOD/no-backup.sh"
if UV2800_DRYRUN=0 sh "$MOD/no-backup.sh" > "$TESTDIR/output" 2>&1; then
    echo 'FAIL skip_creation_failure'; exit 1
fi
[ "$(cat "$P/restore")" = old-state ]
echo 'PASS skip_creation_failure_stops_write'

rm "$P/restore"
mkdir "$P/restore"
must_fail write_failure_stops_restore
[ -f "$BK/skip" ]
[ "$(cat "$P/adsp_read")" = 2600 ]
rmdir "$P/restore"
echo old-state > "$P/restore"

# 普通文件不模拟内核 getter，因此写入触发值 1 后会回读 1，必须停止。
must_fail readback_mismatch_stops_restore
[ "$(cat "$P/restore")" = 3100 ]
[ -f "$BK/skip" ]
echo '6 action cases passed'
