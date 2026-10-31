#!/bin/sh
# ============================================================
# uv2800 - 宿主侧 WebUI 协议 smoke（不连设备）
# 用法：sh dev/webui_host_smoke.sh
# 只验证：status ASCII/键、非法输入拒绝、features 默认/标记分支。
# 真机 apply/restore/锁/命名空间/策略 setter 不在本脚本范围。
# ============================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MOD="$ROOT/02-当前最新构建/模块源目录"
WEBUI="$MOD/webui.sh"
FEAT="$MOD/lib/features.sh"
FAIL=0

ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAIL=1; }

[ -f "$WEBUI" ] || { echo "FAIL missing webui.sh"; exit 1; }
[ -f "$FEAT" ] || { echo "FAIL missing lib/features.sh"; exit 1; }

OUT=$(sh "$WEBUI" status 2>/tmp/uv-webui-smoke.err)
RC=$?
[ "$RC" = 0 ] && ok "status rc=0" || bad "status rc=$RC"
printf '%s
' "$OUT" | grep -q '^RESULT=ok$' && ok "status RESULT=ok" || bad "status RESULT"
printf '%s
' "$OUT" | grep -q '^NO_POLICY=no$' && ok "status NO_POLICY=no" || bad "status NO_POLICY"
printf '%s
' "$OUT" | grep -q '^POLICY=' && ok "status POLICY key" || bad "status POLICY key"
if printf '%s
' "$OUT" | LC_ALL=C grep -q '[^ -~]'; then
    bad "status non-ASCII"
else
    ok "status ASCII"
fi
[ -s /tmp/uv-webui-smoke.err ] && bad "status stderr not empty" || ok "status stderr empty"

sh "$WEBUI" set-real-soc 2 >/tmp/uv-webui-smoke.out 2>&1
grep -q 'CODE=invalid_value' /tmp/uv-webui-smoke.out && ok "set-real-soc 2 rejected" || bad "set-real-soc 2"
sh "$WEBUI" policy x >/tmp/uv-webui-smoke.out 2>&1
grep -q 'CODE=invalid_value' /tmp/uv-webui-smoke.out && ok "policy x rejected" || bad "policy x"

# features.sh 分支：用临时目录 + stub，不碰真机
T=/tmp/uv-features-smoke
rm -rf "$T"; mkdir -p "$T"
BK="$T"; XML="$T/devicepolicy.xml"; KEY=test_key
CS="$T/chip_soc"; CAP="$T/capacity"; CAPUE="$T/uevent"
: > "$XML"; : > "$CS"; : > "$CAP"
klog() { :; }
uv_unbind_capacity() { :; }
mount() { return 1; }
nsenter() { return 1; }
su() { case "$*" in *" 4 "*) echo Parcel ;; esac; return 0; }
. "$FEAT"

feature_policy_sync
[ -f "$T/applied" ] && ok "policy default applies" || bad "policy default"
touch "$T/no_policy"
feature_policy_sync
[ -f "$T/no_policy" ] && [ ! -f "$T/applied" ] && ok "no_policy restores" || bad "no_policy"
rm -f "$T/no_policy" "$T/applied"
feature_policy_apply
[ -f "$T/applied" ] && ok "policy re-apply" || bad "policy re-apply"
touch "$T/skip"
feature_policy_sync
[ -f "$T/skip" ] && [ ! -f "$T/applied" ] && ok "skip restores" || bad "skip"

rm -rf "$T" /tmp/uv-webui-smoke.err /tmp/uv-webui-smoke.out
[ "$FAIL" = 0 ] && echo "RESULT=ok" || echo "RESULT=fail"
exit "$FAIL"
