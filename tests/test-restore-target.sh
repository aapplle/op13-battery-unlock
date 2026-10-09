#!/system/bin/sh
# Android sh 上执行：sh test-restore-target.sh /path/to/restore-target.sh
# 【v10.8 研究存档】依赖 v10.8 的 restore-target.sh 与 /proc/oplus-votable
# 投票路径；v11 起这些已由 restore.sh + resume 参数取代，本测试不再适用。
set -eu
. "$1"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
DIR="$TESTDIR/TARGET_TERM_VOLTAGE"
mkdir -p "$DIR"
passed=0

fixture() {
    echo 0 > "$DIR/force_active"
    cat > "$DIR/status" <<EOF
TARGET_TERM_VOLTAGE: DEEP_COUNT_VOTER: en=1 v=$1
TARGET_TERM_VOLTAGE: effective=DEEP_COUNT_VOTER type=Max v=$1
EOF
}
ok() {
    actual=$(uv_restore_target "$TESTDIR") || { echo "FAIL $1: rejected valid target"; exit 1; }
    [ "$actual" = "$2" ] || { echo "FAIL $1: got $actual, expected $2"; exit 1; }
    passed=$((passed+1))
    echo "PASS $1"
}
fail() {
    if actual=$(uv_restore_target "$TESTDIR" 2>/dev/null); then
        echo "FAIL $1: accepted $actual"; exit 1
    fi
    [ -z "$actual" ] || { echo "FAIL $1: emitted target on failure"; exit 1; }
    passed=$((passed+1))
    echo "PASS $1"
}

fixture 3100
echo 3000 > "$TESTDIR/adsp_orig.txt"
ok historical_3000_is_not_target 3100
[ "$(cat "$TESTDIR/adsp_orig.txt")" = 3000 ]
fixture 3250
ok no_hardcoded_3100 3250
fixture 3200
ok changed_live_strategy 3200
fixture 3100
printf 'TARGET_TERM_VOLTAGE: OTHER_VOTER: en=0 v=3300\n' >> "$DIR/status"
ok disabled_vote_is_ignored 3100
echo 1 > "$DIR/force_active"
fail forced_override
fixture 3100
rm "$DIR/force_active"
fail missing_force_state
fixture 3100
echo false > "$DIR/force_active"
fail malformed_force_state
fixture 3100
rm "$DIR/status"
fail missing_status
fixture 3100
echo 'TARGET_TERM_VOLTAGE: effective=DEEP_COUNT_VOTER type=Max v=3100' > "$DIR/status"
fail missing_enabled_winner
fixture 3100
sed 's/en=1/en=0/' "$DIR/status" > "$TESTDIR/out"
mv "$TESTDIR/out" "$DIR/status"
fail disabled_winner
fixture 3100
sed 's/en=1 v=3100/en=1 v=3000/' "$DIR/status" > "$TESTDIR/out"
mv "$TESTDIR/out" "$DIR/status"
fail inconsistent_snapshot
fixture 3100
echo 'TARGET_TERM_VOLTAGE: effective=DEEP_COUNT_VOTER type=Max v=3100' >> "$DIR/status"
fail duplicate_effective
fixture 3100
echo 'TARGET_TERM_VOLTAGE: DEEP_COUNT_VOTER: en=1 v=3000' >> "$DIR/status"
fail duplicate_client
fixture 2800
fail hooked_value
fixture 2600
fail unlocked_value
fixture 5000
fail out_of_driver_range
fixture invalid
fail malformed_voltage
fixture 3100
sed 's/TARGET_TERM_VOLTAGE/GAUGE_TERM_VOLTAGE/g' "$DIR/status" > "$TESTDIR/out"
mv "$TESTDIR/out" "$DIR/status"
fail wrong_votable
fixture 3100
sed 's/type=Max/type=Unknown/' "$DIR/status" > "$TESTDIR/out"
mv "$TESTDIR/out" "$DIR/status"
fail unknown_format
echo "$passed restore-target cases passed"
