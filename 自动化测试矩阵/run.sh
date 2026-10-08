#!/usr/bin/env bash
# ============================================================
# uv2800 全场景回归测试 —— 唯一入口（子代理只需会跑这一个文件）
#
#   ./run.sh                    自动判定启动路线 → 跑该路线的用例集
#   ./run.sh T9                 只跑指定组
#   ./run.sh --no-reboot        跳过需要重启的用例
#   ./run.sh --with-reboot      标准启动路线下也跑「需重启」用例（默认跳过）
#   ./run.sh --list             列出所有用例（含路线适用性）
#   ./run.sh --resume           续跑（跳过本目录上次已 PASS 的用例）
#   ./run.sh --with-dt          额外跑【可选组 TD】：uv_dt_orig 失败注入（宿主侧，无需设备、秒级）
#                               等价：UV_DT=1 ./run.sh   或   ./run.sh TD
#                               默认不跑；开启也不会改变其它用例的判定与计数
#
# 【启动路线分支】dev/route.sh 自动判定（可用 UV_ROUTE 覆盖）
#   standard  标准启动：KSU 在 init_boot 随 boot 加载 → post-fs-data.sh 会执行。
#             默认只跑【不需要重启】的用例 —— 这类用户不会没事软重启。
#   late-load 越狱注入：ghostlock → late-load.sh，KSU_LATE_LOAD=1。
#             跑全量（含重启组 + T9 竞态组），这是本项目历史测试的主路线。
#
#   适用性写在每个用例自己的 #CASE 行第三列（缺省 = all）：
#     std          仅标准启动（T10 组）
#     late         仅越狱（标准启动没有 ghostlock 注入这条路径）
#     reboot       需重启：标准启动下默认跳过，加 --with-reboot 才跑
#     std,reboot   两者都要满足
#
# 环境变量：
#   UV_SERIAL   设备序列号（默认自动取第一个 USB 设备）
#   UV_ROUTE    强制路线 standard|late-load（默认由 dev/route.sh 判定）
#   UV_WIFI     无线 adb 地址（可选，如 <DEVICE_IP>:5555）
#   UV_FLOOR    ADSP 派生的 floor（默认 3060 = 新机原厂关机电压）
#   UV_ZIP      模块 zip 路径（默认 = ../一加13解容-v11.zip，即仓库根）
#   UV_DT=1     开启可选组 TD（默认关闭；见下方 TD 组说明）
#
# 输出：results/<时间戳>/{report.json,report.md,logs/}
#   报告自带 window（换 ROM/换内核做兼容性矩阵时直接比对不同 results/）：
#   boot_route / dev_rom / dev_kernel / dev_chgko / dev_profile / 构建 md5
# 退出码：0 = 全 PASS 或全 SKIP；1 = 有 FAIL
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${BASH_SOURCE[0]:-$0}"        # --list / 用例表解析都读本文件自己
DEV_DIR="$HERE/dev"
DEV_TMP=/data/local/tmp/uvtest
FLOOR="${UV_FLOOR:-3060}"   # 规格：FLOOR=3060（= 新机原厂关机电压 = 电量计模型计数下限）
# P2-12 修复（2026-10-04）：默认改为当前构建产物（原指向已不存在的 ../ksu-module/v10.19.zip）
ZIP="${UV_ZIP:-$HERE/../一加13解容-v11.zip}"
JAILBREAK_CMD="/data/local/tmp/ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${UV_OUT:-$HERE/results/$TS}"   # UV_OUT 可覆盖（冒烟/试跑时避免污染 results/）
declare -A DV=()   # P2-14：设备/内核/驱动版本戳（采集见 dev/devver.sh）
declare -A R=()    # T9：竞态/残留快照（采集见 dev/racesnap.sh）

# ---------------- 用例表：解析本文件的 #CASE 行（ID|名称|适用性）----------------
declare -A SCOPE=() CNAME=()
while IFS='|' read -r _id _nm _sc; do
  [ -z "$_id" ] && continue
  SCOPE["$_id"]="${_sc:-all}"; CNAME["$_id"]="$_nm"
done < <(sed -n 's/^#CASE //p' "$SELF")

list_cases() {
  local id
  printf '%-6s %-12s %s\n' "用例" "适用性" "名称"
  for id in $(printf '%s\n' "${!SCOPE[@]}" | sort -V); do
    printf '%-6s %-12s %s\n' "$id" "${SCOPE[$id]}" "${CNAME[$id]}"
  done
}

RESUME=0; NO_REBOOT=0; WITH_REBOOT=0; WITH_DT="${UV_DT:-0}"; WANT=()
ROUTE="${UV_ROUTE:-}"       # standard | late-load | 空 = 自动判定
ROUTE_SRC=""
for a in "$@"; do
  case "$a" in
    --list)   list_cases; exit 0 ;;
    --resume) RESUME=1 ;;
    --no-reboot) NO_REBOOT=1 ;;
    --with-reboot) WITH_REBOOT=1 ;;
    --with-dt)     WITH_DT=1 ;;
    -*) echo "未知参数: $a"; exit 2 ;;
    *) WANT+=("$a") ;;
  esac
done

# ---------------- 基础 ----------------
mkdir -p "$OUT/logs"
PASS=0; FAIL=0; SKIP=0
declare -a JSON_ROWS=()
declare -A S=()          # 设备快照
declare -a CASE_ASSERTS=(); CASE_FAILED=0; CUR_ID=""; CUR_NAME=""

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
say()  { echo "$*"; }
ok()   { echo "${c_grn}  ✓${c_off} $*"; }
bad()  { echo "${c_red}  ✗${c_off} $*"; CASE_FAILED=1; }
warn() { echo "${c_yel}  !${c_off} $*"; }

# ---------------- adb ----------------
ADB=()
DEV=""
resolve_dev() {
  if [ -n "${UV_SERIAL:-}" ]; then ADB=(); DEV="$UV_SERIAL"; return 0; fi
  DEV="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  [ -n "$DEV" ] || return 1
  ADB=()
}
adbs() { timeout 25 adb -s "$DEV" "$@" 2>&1; }

wait_dev() {
  for i in $(seq 1 40); do
    adb devices | awk 'NR>1 && $2=="device"{print $1}' | grep -qx "$DEV" && return 0
    sleep 3
  done
  return 1
}
wait_boot() {
  for i in $(seq 1 60); do
    [ "$(adbs shell getprop sys.boot_completed | tr -d '\r')" = "1" ] && return 0
    sleep 3
  done
  return 1
}

# 推送脚本并以 root 执行（避免 adb shell 双引号里 $var 被设备 shell 提前展开）
# 设备脚本只在 main 里推一次（PUSHED=1），避免每次调用都 adb push（性能杀手）
sh_dev() {
  local f="$1"; shift
  local b; b="$(basename "$f")"
  if [ "${PUSHED:-0}" != "1" ]; then
    timeout 30 adb -s "$DEV" push "$f" "$DEV_TMP/$b" >/dev/null 2>&1 || return 1
  fi
  timeout 60 adb -s "$DEV" shell "su -c 'sh $DEV_TMP/$b $*'" 2>&1
}

# ---------------- 快照与断言 ----------------
snap() {
  local raw k v
  S=()   # 读取失败也必须丢弃前次快照，避免断言使用旧状态。
  raw="$(sh_dev "$DEV_DIR/snap.sh")" || { collection_failed "snap 读取失败"; return 1; }
  while IFS='=' read -r k v; do
    [ -n "$k" ] && S["$k"]="$v"
  done <<< "$raw"
  [ "${S[ts]:-}" != "" ] || { S=(); collection_failed "snap 内容异常"; return 1; }
  echo "$raw" > "$OUT/logs/${CUR_ID:-snap}.snap"
  return 0
}

collection_failed() {
  bad "$1"
  CASE_ASSERTS+=("FAIL|$1|collection|failed|fresh data required")
}

# 设备上的模块是否与 zip【逐文件全等】（比只比 .ko md5 更强：脚本被换也能发现）
# 用途：版本一致 + 逐文件一致 → 免卸载重装（标准启动路线下能省掉一次软重启）
same_build() {
  [ -f "$ZIP" ] || return 1
  local files f h="" devlist
  files="$(unzip -Z1 "$ZIP" 2>/dev/null | grep -v '/$' | grep -v '^customize.sh$' | grep -v '^META-INF/')"
  [ -n "$files" ] || return 1
  for f in $files; do
    h="$h$(unzip -p "$ZIP" "$f" 2>/dev/null | md5sum | cut -d' ' -f1)  $f
"
  done
  # ⚠️ 必须压成单行：多行 $files 会让 su -c 的单引号里出现换行，后续文件名被当命令执行
  local flist; flist="$(printf '%s' "$files" | tr '\n' ' ')"
  devlist="$(timeout 25 adb -s "$DEV" shell "su -c 'cd /data/adb/modules/uv2800 2>/dev/null && md5sum $flist'" 2>/dev/null | tr -d '\r')"
  [ -n "$devlist" ] || return 1
  [ "$(printf '%s\n' "$h" | grep -v '^$' | sort)" = "$(printf '%s\n' "$devlist" | grep -v '^$' | sort)" ]
}

# 确保模块【已安装且已加载】（测试前提）：缺失 → ksud 安装 → insmod → 应用解耦态
ensure_module() {
  # 版本对齐：设备版本 ≠ zip 版本，或 zip md5 与上次安装记录不同 → 重装被测构建
  # （版本号常不变，只改代码时必须靠 md5 才能发现差异）
  local zipver devver zipmd5 devmd5
  zipver="$(unzip -p "$ZIP" module.prop 2>/dev/null | sed -n 's/^version=//p' | tr -d "\r")"
  devver="$(timeout 20 adb -s "$DEV" shell "su -c 'sed -n s/^version=//p /data/adb/modules/uv2800/module.prop'" 2>/dev/null | tr -d "\r")"
  zipmd5="$(md5sum "$ZIP" 2>/dev/null | cut -d" " -f1)"
  devmd5="$(timeout 20 adb -s "$DEV" shell "su -c 'cat /data/adb/uv2800_backup/.zip_md5 2>/dev/null'" 2>/dev/null | tr -d "\r")"
  # 免重装快路径（2026-10-04 增）：设备上的模块与 zip 逐文件全等 → 就是同一构建，
  #   只补 .zip_md5 记录。否则「无 md5 记录」会触发一次没必要的卸载重装 + 软重启。
  ADOPTED=0
  if [ -f "$ZIP" ] && [ -n "$zipver" ] && [ "$zipver" = "$devver" ] \
     && timeout 20 adb -s "$DEV" shell "su -c '[ -f /data/adb/modules/uv2800/service.sh ]'" >/dev/null 2>&1 \
     && same_build; then
    ADOPTED=1
    say "设备模块与 zip 逐文件一致（$zipver / zip md5 ${zipmd5:0:8}）→ 免重装"
    timeout 20 adb -s "$DEV" shell "su -c 'mkdir -p /data/adb/uv2800_backup; echo $zipmd5 > /data/adb/uv2800_backup/.zip_md5'" >/dev/null 2>&1
  fi
  # 三条任一成立就重装：版本不同 / md5 不同 / 【无 md5 记录】（首次引入该机制）
  if [ "$ADOPTED" != 1 ] && [ -n "$zipver" ] && { [ "$zipver" != "$devver" ] || [ -z "$devmd5" ] || [ "$zipmd5" != "$devmd5" ]; }; then
    say "⚠️ 构建不一致：设备=$devver/${devmd5:-无记录}  被测=$zipver/$zipmd5 → 卸载并重装"
    timeout 60 adb -s "$DEV" shell "su -c '/data/adb/ksu/bin/ksud module uninstall uv2800'" >/dev/null 2>&1
    timeout 30 adb -s "$DEV" shell "su -c 'rmmod uv2800'" >/dev/null 2>&1
    timeout 30 adb -s "$DEV" shell "su -c 'rm -rf /data/adb/modules/uv2800'" >/dev/null 2>&1
    sleep 2
  fi
  if ! timeout 20 adb -s "$DEV" shell "su -c '[ -f /data/adb/modules/uv2800/service.sh ]'" >/dev/null 2>&1; then
    say "模块未安装 → 从 zip 安装（被测版本）"
    [ -f "$ZIP" ] || { echo "✗ 找不到 zip: $ZIP（用 UV_ZIP 指定）"; exit 2; }
    echo "    zip: $ZIP  ($(stat -c%s "$ZIP" 2>/dev/null) B)"
    timeout 60 adb -s "$DEV" push "$ZIP" "$DEV_TMP/module.zip" >/dev/null 2>&1 || { echo "✗ zip 推送失败"; exit 2; }
    local out
    out="$(timeout 120 adb -s "$DEV" shell "su -c '/data/adb/ksu/bin/ksud module install $DEV_TMP/module.zip'" 2>&1)"
    echo "$out" | grep -v "^$" | sed "s/^/    /"
    sleep 3
    # ksud 只把文件放到 modules_update（modules/ 下仅有 module.prop + update 标记）
    # → 必须一次【软重启】让 KSU 真正激活（正常流程）
    say "    装到 modules_update → 软重启激活（正常流程）"
    soft_reboot || { echo "✗ 安装后软重启失败，测试终止"; exit 2; }
    local ok=0 i
    for i in $(seq 1 30); do
      timeout 20 adb -s "$DEV" shell "su -c '[ -f /data/adb/modules/uv2800/service.sh ]'" >/dev/null 2>&1 && { ok=1; break; }
      sleep 3
    done
    [ "$ok" = 1 ] || { echo "✗ 软重启后 90s 内仍无 service.sh（激活失败）"; exit 2; }
    say "    ✅ 安装已激活"
    timeout 20 adb -s "$DEV" shell "su -c 'mkdir -p /data/adb/uv2800_backup; echo $zipmd5 > /data/adb/uv2800_backup/.zip_md5'" >/dev/null 2>&1
  fi
  snap >/dev/null 2>&1
  if [ "${S[module_loaded]:-0}" != "1" ]; then
    say "模块未加载 → insmod"
    local out2
    out2="$(timeout 30 adb -s "$DEV" shell "su -c 'insmod /data/adb/modules/uv2800/uv2800.ko'" 2>&1)"
    echo "$out2" | grep -v "^$" | sed "s/^/    /"
    local ok2=0 i2
    for i2 in $(seq 1 15); do
      sleep 2
      snap >/dev/null 2>&1
      [ "${S[module_loaded]:-0}" = "1" ] && { ok2=1; break; }
    done
    [ "$ok2" = 1 ] || { echo "✗ insmod 失败，测试终止"; exit 2; }
  fi
  # P2-16 修复（2026-10-04）：设备上的 .ko 可能与新装的 zip 不同（重装只替换文件，
  #   而内存里仍是旧模块 —— 旧 .ko 的 module_loaded=1 会让上面的 insmod 分支被跳过，
  #   结果是【用新脚本测旧模块】。这里用 soft-reboot 卸载内存中的旧 .ko，
  #   让 KSU 的 late-load 重新加载新版（越狱模式下 rmmod 会崩，历史教训）。
  local zipkomd5 devkomd5
  zipkomd5="$(unzip -p "$ZIP" uv2800.ko 2>/dev/null | md5sum | cut -d" " -f1)"
  devkomd5="$(timeout 20 adb -s "$DEV" shell "su -c 'md5sum /data/adb/modules/uv2800/uv2800.ko 2>/dev/null'" 2>/dev/null | cut -d" " -f1 | tr -d "\r")"
  if [ -n "$zipkomd5" ] && [ -n "$devkomd5" ] && [ "$zipkomd5" != "$devkomd5" ]; then
    say "⚠️ 模块 .ko 与 zip 不一致（设备=${devkomd5:0:8} zip=${zipkomd5:0:8}）→ soft-reboot 重载新模块"
    soft_reboot || { echo "✗ .ko 重载用 soft-reboot 失败，测试终止"; exit 2; }
    local _k=0 _i
    for _i in $(seq 1 20); do
      snap >/dev/null 2>&1
      [ "${S[module_loaded]:-0}" = "1" ] && { _k=1; break; }
      sleep 3
    done
    if [ "$_k" != "1" ]; then
      say "  内存中无 uv2800 → insmod 新 .ko"
      timeout 30 adb -s "$DEV" shell "su -c 'insmod /data/adb/modules/uv2800/uv2800.ko'" >/dev/null 2>&1
      sleep 3; snap >/dev/null 2>&1
    fi
  fi
  sh_dev "$DEV_DIR/apply.sh" decouple 2800 >/dev/null 2>&1
  sleep 3
  snap >/dev/null 2>&1
  TESTED_ZIP="$ZIP"
  TESTED_VER="$(unzip -p "$ZIP" module.prop 2>/dev/null | sed -n 's/^version=//p' | tr -d "\r")"
  TESTED_MD5="$(md5sum "$ZIP" 2>/dev/null | cut -d" " -f1)"
  TESTED_SHA256="$(sha256sum "$ZIP" 2>/dev/null | cut -d" " -f1)"
  say "模块就绪：版本=$TESTED_VER  target=${S[param_target]:-?} adsp=${S[param_adsp]:-?} resume=${S[param_resume]:-?} vbat_uv=${S[vbat_uv]:-?}"
}

# 轮询快照直到 key == 期望值（代替固定 sleep，通常 1~2s 就返回）
wait_key() {
  local k="${1:-}" exp="${2:-}" max="${3:-10}" i=0
  [ -z "$k" ] && return 1
  while [ "$i" -lt "$max" ]; do
    snap >/dev/null 2>&1 || return 1
    [ "${S["$k"]:-}" = "$exp" ] 2>/dev/null && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

derived_adsp() {
  local v="$1"
  local off=$(( FLOOR - v ))
  [ "$off" -lt 0 ] && off=0
  echo $(( v - off ))
}

# T9：竞态/残留快照（模块唯一性 / 残留进程 / 僵尸 / 状态一致性）
race_snap() {
  local raw k v
  R=()
  raw="$(sh_dev "$DEV_DIR/racesnap.sh")" || { collection_failed "racesnap 读取失败"; return 1; }
  while IFS='=' read -r k v; do
    [ -n "$k" ] && R["$k"]="$v"
  done <<< "$raw"
  [ -n "${R[mods]:-}" ] || { R=(); collection_failed "racesnap 内容异常"; return 1; }
  echo "$raw" > "$OUT/logs/${CUR_ID:-racesnap}.racesnap"
  return 0
}

# 采集启动路线（dev/route.sh）→ 合并进 DV[]；UV_ROUTE 可强制覆盖
refresh_route() {
  local raw k v
  for k in "${ROUTE_KEYS[@]:-}"; do [ -z "$k" ] || unset 'DV[$k]'; done
  ROUTE_KEYS=()
  ROUTE=unknown; ROUTE_SRC=""
  if [ -n "${UV_ROUTE:-}" ]; then
    ROUTE="$UV_ROUTE"; ROUTE_SRC=env
    DV[boot_route]="$ROUTE"; DV[route_src]=env; DV[route_evidence]="UV_ROUTE 强制指定"
    ROUTE_KEYS=(boot_route route_src route_evidence)
    return 0
  fi
  raw="$(sh_dev "$DEV_DIR/route.sh")" || { collection_failed "route.sh 采集失败"; return 1; }
  while IFS='=' read -r k v; do
    if [ -n "$k" ]; then DV["$k"]="$v"; ROUTE_KEYS+=("$k"); fi
  done <<< "$raw"
  ROUTE="${DV[boot_route]:-unknown}"; ROUTE_SRC="${DV[route_src]:-?}"
  [ "$ROUTE" != unknown ] || { collection_failed "route.sh 路线不明"; return 1; }
  return 0
}

# 断言竞态快照（与 A 同一套判定，只是数据源为 R）
AR() {
  local d="$1" k="$2" op="$3"; shift 3
  local got="${R[$k]:-<缺失>}" exp="$*"
  case "$got" in '<缺失>'|'?') collection_failed "$d：$k 缺少有效读数"; return 1 ;; esac
  local pass=0
  case "$op" in
    eq) [ "$got" = "$exp" ] && pass=1 ;;
    ne) [ "$got" != "$exp" ] && pass=1 ;;
    ge) [ "$got" != "?" ] && [ "$got" -ge "$exp" ] 2>/dev/null && pass=1 ;;
    le) [ "$got" != "?" ] && [ "$got" -le "$exp" ] 2>/dev/null && pass=1 ;;
  esac
  if [ $pass = 1 ]; then ok "$d  [$k=$got]"; CASE_ASSERTS+=("PASS|$d|$k|$got|$op $exp")
  else bad "$d  [$k=$got] 期望 $op $exp"; CASE_ASSERTS+=("FAIL|$d|$k|$got|$op $exp"); fi
}

# A <说明> <key> <op> <期望...>
A() {
  local d="$1" k="$2" op="$3"; shift 3
  local got="${S[$k]:-<缺失>}" exp="$*"
  case "$got" in '<缺失>'|'?') collection_failed "$d：$k 缺少有效读数"; return 1 ;; esac
  local pass=0
  case "$op" in
    eq)      [ "$got" = "$exp" ] && pass=1 ;;
    ne)      [ "$got" != "$exp" ] && pass=1 ;;
    ge)      [ "$got" != "?" ] && [ "$got" -ge "$exp" ] 2>/dev/null && pass=1 ;;
    le)      [ "$got" != "?" ] && [ "$got" -le "$exp" ] 2>/dev/null && pass=1 ;;
    bt)      [ "$got" != "?" ] && [ "$got" -ge "$1" ] 2>/dev/null && [ "$got" -le "$2" ] 2>/dev/null && pass=1 ;;
    contains) case "$got" in *"$exp"*) pass=1 ;; esac ;;
  esac
  if [ $pass = 1 ]; then ok "$d  [$k=$got]"; CASE_ASSERTS+=("PASS|$d|$k|$got|$op $exp")
  else bad "$d  [$k=$got] 期望 $op $exp"; CASE_ASSERTS+=("FAIL|$d|$k|$got|$op $exp"); fi
}

# AD：断言 run.sh 采集的「路线 / 版本戳」(DV[])，数据源不是设备快照
AD() {
  local d="$1" k="$2" op="$3"; shift 3
  local got="${DV[$k]:-<缺失>}" exp="$*"
  case "$got" in '<缺失>'|'?') collection_failed "$d：$k 缺少有效读数"; return 1 ;; esac
  local pass=0
  case "$op" in
    eq)       [ "$got" = "$exp" ] && pass=1 ;;
    ne)       [ "$got" != "$exp" ] && pass=1 ;;
    ge)       [ "$got" != "?" ] && [ "$got" -ge "$exp" ] 2>/dev/null && pass=1 ;;
    le)       [ "$got" != "?" ] && [ "$got" -le "$exp" ] 2>/dev/null && pass=1 ;;
    contains) case "$got" in *"$exp"*) pass=1 ;; esac ;;
  esac
  if [ $pass = 1 ]; then ok "$d  [$k=$got]"; CASE_ASSERTS+=("PASS|$d|$k|$got|$op $exp")
  else bad "$d  [$k=$got] 期望 $op $exp"; CASE_ASSERTS+=("FAIL|$d|$k|$got|$op $exp"); fi
}

# 检查设备日志里是否出现某模式
A_log() {
  local d="$1" pat="$2"
  local n="${3:-120}"
  local t; t="$(sh_dev "$DEV_DIR/logtail.sh" "$n")" || { collection_failed "日志采集失败"; return 1; }
  if echo "$t" | grep -q -- "$pat"; then ok "$d"; CASE_ASSERTS+=("PASS|$d|log|hit|$pat")
  else bad "$d  （日志未命中：$pat）"; CASE_ASSERTS+=("FAIL|$d|log|miss|$pat"); fi
}

# ---------------- 用例框架 ----------------
case_begin() { CUR_ID="$1"; CUR_NAME="$2"; CASE_ASSERTS=(); CASE_FAILED=0; say ""; say "── $CUR_ID $CUR_NAME"; }
case_end() {
  local st=FAIL
  if [ "$CASE_FAILED" = 0 ]; then st=PASS; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  say "   → $st"
  local a; for a in "${CASE_ASSERTS[@]:-}"; do
    JSON_ROWS+=("{\"case\":\"$CUR_ID\",\"name\":\"$CUR_NAME\",\"result\":\"$st\",\"assert\":\"${a//\"/}\"}")
  done
}
skip_case() { CUR_ID="$1"; CUR_NAME="$2"; say ""; say "── $CUR_ID $CUR_NAME"; warn "SKIP：$3"; SKIP=$((SKIP+1))
  JSON_ROWS+=("{\"case\":\"$CUR_ID\",\"name\":\"$CUR_NAME\",\"result\":\"SKIP\",\"assert\":\"$3\"}"); }

# 路线适用性判定：输出跳过原因（空 = 可跑）。适用性见本文件顶部说明
route_gate() {
  local sc="${SCOPE[$1]:-all}" t only_std=0 only_late=0 need_rb=0
  for t in ${sc//,/ }; do
    case "$t" in
      std)    only_std=1 ;;
      late)   only_late=1 ;;
      reboot) need_rb=1 ;;
    esac
  done
  if [ "$only_std" = 1 ] && [ "$ROUTE" != standard ]; then
    echo "标准启动专属（当前路线=$ROUTE）"; return
  fi
  if [ "$only_late" = 1 ] && [ "$ROUTE" != late-load ]; then
    echo "越狱(late-load)专属（当前路线=$ROUTE）：标准启动没有 ghostlock 注入路径"; return
  fi
  if [ "$need_rb" = 1 ] && [ "$ROUTE" = standard ] && [ "$WITH_REBOOT" != 1 ]; then
    echo "需重启：标准启动路线默认跳过（加 --with-reboot 启用）"; return
  fi
  echo ""
}

want() {  # want <用例ID> —— 在 case_begin 之前调用，未选中则完全静默
  local id="$1"
  [ ${#WANT[@]} -eq 0 ] && return 0
  local g; for g in "${WANT[@]}"; do case "$id" in "$g"*) return 0 ;; esac; done
  return 1
}

# ---------------- 动作封装 ----------------
apply_dev() {
  local rc=0
  sh_dev "$DEV_DIR/apply.sh" "$@" || rc=$?
  [ "$rc" -eq 0 ] || bad "设备动作 $1 失败（rc=$rc）"
  return "$rc"
}
ensure_decouple() {
  local vs="${1:-2800}"
  snap >/dev/null 2>&1 || return 1
  # 快路径：已是解耦态且 target 正确 → 不重跑 service.sh（单次省 15~20s）
  if [ "${S[skip]:-}" = "no" ] && [ "${S[param_target]:-}" = "$vs" ]; then return 0; fi
  apply_dev decouple "$vs" >/dev/null 2>&1 || return 1
  wait_key param_target "$vs" 12
}
apply_target() {
  apply_dev target "$1" >/dev/null 2>&1 || return 1
  wait_key param_target "$1" 12
}
ensure_factory() {
  # skip 只是恢复意图；必须重新成功执行 action 并确认整个事务已完成。
  apply_dev factory >/dev/null 2>&1 || { bad "恢复动作失败"; return 1; }
  snap || return 1
  assert_factory_completed
}

factory_state_ready() {
  local target="${S[restore_target]:-}"
  case "$target" in [23][0-9][0-9][0-9]) ;; *) return 1 ;; esac
  [ "$target" -ge 2900 ] && [ "$target" -le 3500 ] &&
    [ "${S[skip]:-}" = yes ] && [ "${S[restore_pending]:-}" = no ] &&
    [ "${S[param_target]:-}" = "$target" ] && [ "${S[param_adsp]:-}" = "$target" ] &&
    [ "${S[adsp_read]:-}" = "$target" ] && [ "${S[adsp_state]:-}" = "$target" ] &&
    [ "${S[vbat_uv]:-}" = "$target" ] && [ "${S[param_resume]:-}" = 0 ] &&
    [ "${S[bind_layers]:-}" = 0 ]
}

assert_factory_completed() {
  A "恢复事务已完成：pending=no" restore_pending eq no
  A "本次实时恢复目标有效" restore_target bt 2900 3500
  factory_state_ready || { bad "恢复记录与实时硬件/挂载状态不一致"; return 1; }
}

wait_factory_state() {
  local remaining="${1:-20}"
  while [ "$remaining" -gt 0 ]; do
    snap || return 1
    if factory_state_ready; then assert_factory_completed; return; fi
    remaining=$((remaining-1))
    [ "$remaining" -eq 0 ] || sleep 1
  done
  assert_factory_completed
}

# 每条 T2 都独立执行一次解耦→恢复，单例和 --resume 不依赖 T2.1 的副作用。
setup_factory_case() {
  ensure_decouple 2800 || { bad "T2 解耦准备失败"; return 1; }
  ensure_factory
}

soft_reboot() {
  local before after i
  before="$(timeout 15 adb -s "$DEV" shell pidof system_server 2>/dev/null | tr -d "\r")"
  local out; out="$(sh_dev "$DEV_DIR/softreboot.sh" 2>&1)"
  echo "$out" | grep -q NO_KSUD && return 1
  # 框架重启的可靠判据：system_server PID 变化
  for i in $(seq 1 45); do
    sleep 2
    after="$(timeout 15 adb -s "$DEV" shell pidof system_server 2>/dev/null | tr -d "\r")"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      local j
      for j in $(seq 1 20); do
        [ "$(timeout 10 adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = "1" ] && break
        sleep 2
      done
      sleep 3
      return 0
    fi
  done
  return 1
}
# 硬重启（不注入）：标准启动路线用 —— KSU 在 init_boot，开机即 root
hard_reboot_plain() {
  adb -s "$DEV" reboot >/dev/null 2>&1
  sleep 5
  wait_dev || return 1
  wait_boot || return 1
  local i
  for i in $(seq 1 30); do
    adb -s "$DEV" shell "su -c id" 2>/dev/null | grep -q "uid=0" && { sleep 5; return 0; }
    sleep 2
  done
  return 1
}

# 硬重启 + ghostlock 注入：late-load 越狱路线用（开机时还没有 su）
hard_reboot_jailbreak() {
  adb -s "$DEV" reboot >/dev/null 2>&1
  sleep 5
  wait_dev || return 1
  wait_boot || return 1
  local i
  # 等系统服务就绪（此时 su 还不可用，靠 adb 可用性判断）
  for i in $(seq 1 20); do
    adb -s "$DEV" shell "getprop sys.boot_completed" 2>/dev/null | grep -q "1" && break
    sleep 2
  done
  # 实测注入耗时 ≤20s（C15/6.6.30、6.6.66 均如此）；cap 60s 只为「挂死时早失败」，
  # 正常路径命令一返回就走，不会白等
  timeout 60 adb -s "$DEV" shell "$JAILBREAK_CMD" >/dev/null 2>&1
  for i in $(seq 1 40); do
    adb -s "$DEV" shell "su -c id" 2>/dev/null | grep -q "uid=0" && { sleep 4; return 0; }
    sleep 1
  done
  return 1
}

# ============================================================
# 用例定义
# ============================================================
#CASE T0.1|环境就绪：adb + su + 模块已安装
t_T0_1() { want T0.1 || return 0; case_begin T0.1 "环境就绪（adb+su+模块已装）"
  snap || { bad "snap 采集失败"; case_end; return; }
  A "模块已加载" module_loaded eq 1
  A "模块目录存在" applied ne __never__
  case_end; }

#CASE T0.2|快照可采集（关键 key 齐全）
t_T0_2() { want T0.2 || return 0; case_begin T0.2 "快照关键 key 齐全"
  snap || { bad "snap 失败"; case_end; return; }
  local k miss=0
  for k in module_loaded param_target param_resume adsp_read vbat_uv chip_soc capacity bind_layers skip adsp_orig restore_target restore_pending target_file count; do
    [ "${S[$k]:-}" = "" ] && { bad "缺 key: $k"; miss=1; }
  done
  [ $miss = 0 ] && ok "关键 key 齐全"
  case_end; }

#CASE T1.1|解耦态：uv_target_mv == V_s
t_T1_1() { want T1.1 || return 0; case_begin T1.1 "解耦态 uv_target_mv == V_s"
  ensure_decouple 2800; snap || { bad "snap"; case_end; return; }
  A "uv_target_mv = 2800" param_target eq 2800
  A "skip 不存在" skip eq no
  case_end; }

#CASE T1.2|解耦态：vbat_uv == V_s（hook 即时镜像）
t_T1_2() { want T1.2 || return 0; case_begin T1.2 "解耦态 vbat_uv == V_s"
  snap; A "vbat_uv = 2800（即时镜像，无需插拔）" vbat_uv eq 2800
  A "resume=0（hook 生效）" param_resume eq 0
  case_end; }

#CASE T1.3|解耦态：ADSP == 派生值 V_s - max(0, FLOOR-V_s)
t_T1_3() { want T1.3 || return 0; case_begin T1.3 "解耦态 ADSP == 派生值"
  snap; local exp; exp="$(derived_adsp 2800)"
  A "adsp_read = $exp（FLOOR=$FLOOR）" adsp_read eq "$exp"
  case_end; }

#CASE T1.4|解耦态：bind-mount 生效
t_T1_4() { want T1.4 || return 0; case_begin T1.4 "解耦态 bind-mount 生效"
  snap; A "bind 层数 >= 1" bind_layers ge 1; A "capacity == chip_soc" capacity eq "${S[chip_soc]:-?}"
  case_end; }

#CASE T1.5|解耦态：无残留后台进程
t_T1_5() { want T1.5 || return 0; case_begin T1.5 "解耦态无残留进程"
  snap; A "service.sh 残留进程 = 0" svc_proc eq 0
  A "retry 进程 = 0（v10 遗留，v11 恒真）" retry_proc eq 0
  case_end; }

#CASE T2.1|「执行」→ skip 创建 + 进恢复模式
t_T2_1() { want T2.1 || return 0; case_begin T2.1 "执行 → skip 创建"
  setup_factory_case || { case_end; return; }
  A "skip == yes" skip eq yes
  case_end; }

#CASE T2.2|「执行」→ ADSP 回写原厂值
t_T2_2() { want T2.2 || return 0; case_begin T2.2 "执行 → ADSP = 原厂值"
  setup_factory_case || { case_end; return; }; local ORIG="${S[restore_target]}"
  A "adsp_read = 原厂($ORIG)" adsp_read eq "$ORIG"
  A "adsp_state = 原厂($ORIG)" adsp_state eq "$ORIG"
  case_end; }

#CASE T2.3|「执行」→ uv_target_mv = 原厂值
t_T2_3() { want T2.3 || return 0; case_begin T2.3 "执行 → uv_target_mv = 原厂值"
  setup_factory_case || { case_end; return; }; local ORIG="${S[restore_target]}"
  A "uv_target_mv = 原厂($ORIG)" param_target eq "$ORIG"
  case_end; }

#CASE T2.4|「执行」→ vbat_uv 立即跟随（v10.17 核心修复，不插拔）
t_T2_4() { want T2.4 || return 0; case_begin T2.4 "执行 → vbat_uv 立即 = 原厂（不插拔）"
  setup_factory_case || { case_end; return; }; local ORIG="${S[restore_target]}"
  A "vbat_uv = 原厂($ORIG)" vbat_uv eq "$ORIG"
  A "resume=0（已退出恢复模式）" param_resume eq 0
  case_end; }

#CASE T2.5|「执行」→ bind 解绑
t_T2_5() { want T2.5 || return 0; case_begin T2.5 "执行 → bind 已解绑"
  setup_factory_case || { case_end; return; }
  A "bind 层数 = 0" bind_layers eq 0
  case_end; }

#CASE T3.1|skip 无 + 软重启 → 解耦保持|reboot
t_T3_1() { want T3.1 || return 0; case_begin T3.1 "skip 无 + 软重启 → 解耦保持"
  [ "$NO_REBOOT" = 1 ] && { skip_case T3.1 x "--no-reboot"; return; }
  ensure_decouple 2800; soft_reboot || { skip_case T3.1 x "软重启不可用"; return; }
  snap; local exp; exp="$(derived_adsp 2800)"
  A "uv_target_mv = 2800" param_target eq 2800
  A "vbat_uv = 2800" vbat_uv eq 2800
  A "adsp_read = $exp" adsp_read eq "$exp"
  A "bind 生效" bind_layers ge 1
  A "skip = no" skip eq no
  case_end; }

#CASE T3.2|skip 有 + 软重启 → 出厂保持|reboot
t_T3_2() { want T3.2 || return 0; case_begin T3.2 "skip 有 + 软重启 → 出厂保持"
  [ "$NO_REBOOT" = 1 ] && { skip_case T3.2 x "--no-reboot"; return; }
  setup_factory_case || { case_end; return; }
  soft_reboot || { skip_case T3.2 x "软重启不可用"; return; }
  wait_factory_state || { case_end; return; }; local ORIG="${S[restore_target]}"
  A "uv_target_mv = 原厂($ORIG)" param_target eq "$ORIG"
  A "vbat_uv = 原厂($ORIG)" vbat_uv eq "$ORIG"
  A "adsp_read = 原厂($ORIG)" adsp_read eq "$ORIG"
  A "bind 层数 = 0" bind_layers eq 0
  case_end; }

#CASE T4.1|硬重启+越狱，skip 无 → 解耦（零插拔）|late
t_T4_1() { want T4.1 || return 0; case_begin T4.1 "硬重启+越狱（skip 无）→ 解耦，零插拔"
  [ "$NO_REBOOT" = 1 ] && { skip_case T4.1 x "--no-reboot"; return; }
  ensure_decouple 2800
  hard_reboot_jailbreak || { skip_case T4.1 x "硬重启/越狱失败"; return; }
  snap; local exp; exp="$(derived_adsp 2800)"
  A "uv_target_mv = 2800" param_target eq 2800
  A "vbat_uv = 2800" vbat_uv eq 2800
  A "adsp_read = $exp（已捕获 uv_dev）" adsp_read eq "$exp"
  A "bind 生效" bind_layers ge 1
  A_log "日志含「主动触发 deep_dischg」" "主动触发 deep_dischg"
  case_end; }

#CASE T4.2|硬重启+越狱，skip 有 → 出厂（零插拔）|late
t_T4_2() { want T4.2 || return 0; case_begin T4.2 "硬重启+越狱（skip 有）→ 出厂"
  [ "$NO_REBOOT" = 1 ] && { skip_case T4.2 x "--no-reboot"; return; }
  setup_factory_case || { case_end; return; }
  hard_reboot_jailbreak || { skip_case T4.2 x "硬重启/越狱失败"; return; }
  wait_factory_state || { case_end; return; }; local ORIG="${S[restore_target]}"
  A "uv_target_mv = 原厂($ORIG)" param_target eq "$ORIG"
  A "vbat_uv = 原厂($ORIG)" vbat_uv eq "$ORIG"
  A "adsp_read = 原厂($ORIG)" adsp_read eq "$ORIG"
  A "bind 层数 = 0" bind_layers eq 0
  case_end; }

#CASE T5.1|解耦态 touch skip + 重启 → 出厂（ADSP 也拉回）|reboot
t_T5_1() { want T5.1 || return 0; case_begin T5.1 "解耦态 touch skip + 重启 → ADSP 拉回原厂"
  [ "$NO_REBOOT" = 1 ] && { skip_case T5.1 x "--no-reboot"; return; }
  ensure_decouple 2800 || { bad "解耦准备失败"; case_end; return; }
  sh_dev "$DEV_DIR/touchskip.sh" >/dev/null 2>&1 || { bad "设置 skip 失败"; case_end; return; }
  soft_reboot || { skip_case T5.1 x "软重启不可用"; return; }
  wait_factory_state || { case_end; return; }; local ORIG="${S[restore_target]}"
  A "adsp_read = 原厂($ORIG)（关键：解耦值必须被拉回）" adsp_read eq "$ORIG"
  A "vbat_uv = 原厂($ORIG)" vbat_uv eq "$ORIG"
  A "skip = yes" skip eq yes
  case_end; }

#CASE T6.1|自定义关机电压 2800 → ADSP 2600
t_T6_1() { want T6.1 || return 0; case_begin T6.1 "target=2800 → ADSP=派生值"
  ensure_decouple 2800; snap; local e; e="$(derived_adsp 2800)"
  A "target_file = 2800" target_file eq 2800
  A "uv_target_mv = 2800" param_target eq 2800
  A "adsp_read = $e" adsp_read eq "$e"
  case_end; }

#CASE T6.2|自定义关机电压 2900 → ADSP 2800
t_T6_2() { want T6.2 || return 0; case_begin T6.2 "target=2900 → ADSP=派生值"
  apply_target 2900; snap; local e; e="$(derived_adsp 2900)"
  A "uv_target_mv = 2900" param_target eq 2900
  A "vbat_uv = 2900" vbat_uv eq 2900
  A "adsp_read = $e" adsp_read eq "$e"
  case_end; }

#CASE T6.3|自定义关机电压 3000 → ADSP 3000（FLOOR 处偏移归零）
t_T6_3() { want T6.3 || return 0; case_begin T6.3 "target=3000 → ADSP=派生值"
  apply_target 3000; snap; local e; e="$(derived_adsp 3000)"
  A "uv_target_mv = 3000" param_target eq 3000
  A "adsp_read = $e" adsp_read eq "$e"
  case_end; }

#CASE T6.4|自定义关机电压 3060 → ADSP 3060
t_T6_4() { want T6.4 || return 0; case_begin T6.4 "target=3060 → ADSP=3060（偏移归零）"
  apply_target 3060; snap; local e; e="$(derived_adsp 3060)"
  A "uv_target_mv = 3060" param_target eq 3060
  A "adsp_read = $e" adsp_read eq "$e"
  case_end; }

#CASE T6.5|越界值 2799 / 3061 → 回退默认 2800
t_T6_5() { want T6.5 || return 0; case_begin T6.5 "越界 target 回退默认"
  apply_target 2799; snap
  A "2799 → 回退 2800" param_target eq 2800
  apply_target 3061; snap
  A "3061 → 回退 2800" param_target eq 2800
  case_end; }

#CASE T6.6|改 target + 重启 → 生效|reboot
t_T6_6() { want T6.6 || return 0; case_begin T6.6 "改 target=2900 + 软重启 → 生效"
  [ "$NO_REBOOT" = 1 ] && { skip_case T6.6 x "--no-reboot"; return; }
  apply_target 2900
  soft_reboot || { skip_case T6.6 x "软重启不可用"; return; }
  snap; local e; e="$(derived_adsp 2900)"
  A "重启后 uv_target_mv = 2900" param_target eq 2900
  A "重启后 adsp_read = $e" adsp_read eq "$e"
  ensure_decouple 2800 >/dev/null 2>&1
  case_end; }

#CASE T7.2|卸载 → 模块清理完备（vbat_uv 由驱动决定，仅观察不断言）|reboot
t_T7_2() { want T7.2 || return 0; case_begin T7.2 "卸载 → 模块清理完备";
  [ "$NO_REBOOT" = 1 ] && { skip_case T7.2 x "--no-reboot"; return; }
  snap; local ORIG="${S[adsp_orig]:-?}"
  say "    卸载（走 KSU 正常卸载，会跑 uninstall.sh）"
  timeout 60 adb -s "$DEV" shell "su -c '/data/adb/ksu/bin/ksud module uninstall uv2800'" >/dev/null 2>&1
  timeout 30 adb -s "$DEV" shell "su -c 'rmmod uv2800'" >/dev/null 2>&1
  sleep 2
  soft_reboot || { skip_case T7.2 x "软重启不可用"; return; }
  sleep 5
  snap
  A "模块已卸载" module_loaded eq 0
  # ⚠️ vbat_uv 不再断言：rmmod 后驱动【主动】回退到 DT uv_thr=2800，模块无法控制（已实测确认）。
  #    下一次开机 vote 才会重新发布 DT term_coeff 的原厂值（本机 $ORIG）——那是驱动行为，不是模块回归。
  say "    观察值：卸载后 vbat_uv=${S[vbat_uv]:-?}   原厂参考值=$ORIG"
  say "    收尾：重装被测版本（后续用例需要）"
  ensure_module >/dev/null 2>&1
  case_end; }

#CASE T8.1|adsp_orig.txt 污染（≤2900）→ 拒绝/隔离
t_T8_1() { want T8.1 || return 0; case_begin T8.1 "adsp_orig 污染 → 拒绝"
  ensure_decouple 2800
  apply_dev pollute_orig 2500 >/dev/null 2>&1 || { case_end; return; }
  ensure_factory || { case_end; return; }
  A "污染值未被当作原厂值回写（adsp_read != 2500）" adsp_read ne 2500
  A "已隔离 .bad 文件" bad_file eq yes
  case_end; }


# ============================================================
# T9 组：竞态 / 残留（连续软重启、rm skip 立即重启、并发竞态）
#   背景：原矩阵只有【单次】重启用例，且 T1.5 断言的是 v11 已删除的 adsp_retry（恒真）。
#   本组用 dev/racesnap.sh 采集「模块唯一性 / 残留进程 / 僵尸 / 状态一致性」。
#   路线适用性：T9.1/T9.2 需多次软重启 → 标准启动下默认跳过（--with-reboot 才跑）；
#               T9.3 并发竞态不需要重启 → 两条路线都跑。
# ============================================================

#CASE T9.1|连续软重启 ×3（back-to-back）→ 无残留累积|reboot
t_T9_1() { want T9.1 || return 0; case_begin T9.1 "连续软重启 x3 -> 无残留累积"
  [ "$NO_REBOOT" = 1 ] && { skip_case T9.1 x "--no-reboot"; return; }
  ensure_decouple 2800
  local i=""
  for i in 1 2 3; do
    soft_reboot || { skip_case T9.1 x "第 $i 次软重启失败"; return; }
  done
  race_snap || { bad "race_snap 失败"; case_end; return; }
  AR "service.sh 残留进程 = 0" svc_procs eq 0
  AR "action.sh 残留进程 = 0" action_procs eq 0
  AR "无任何 uv2800 相关进程" uv_any_procs eq 0
  AR "内核模块唯一（未重复 insmod）" mods eq 1
  AR "解耦态保持：skip 不存在" skip eq no
  AR "解耦态保持：uv_target_mv = 2800" target eq 2800
  AR "解耦态保持：ADSP = 派生值" adsp_hw eq "$(derived_adsp 2800)"
  AR "解耦态保持：vbat_uv = 2800" vbat eq 2800
  case_end; }

#CASE T9.2|rm skip + 立即软重启 → 解耦态重建|reboot
t_T9_2() { want T9.2 || return 0; case_begin T9.2 "rm skip + 立即重启 -> 解耦重建"
  [ "$NO_REBOOT" = 1 ] && { skip_case T9.2 x "--no-reboot"; return; }
  ensure_factory || { case_end; return; }
  local i=""
  for i in 1 2; do
    # rm skip 后【立即】重启，不给 service.sh 完成窗口（构造竞态）
    adb -s "$DEV" shell "su -c 'rm -f /data/adb/uv2800_backup/skip'" >/dev/null 2>&1
    soft_reboot || { skip_case T9.2 x "第 $i 次软重启失败"; return; }
  done
  race_snap || { bad "race_snap 失败"; case_end; return; }
  AR "解耦已重建：skip 不存在" skip eq no
  AR "解耦已重建：uv_target_mv = 2800" target eq 2800
  AR "解耦已重建：ADSP = 派生值" adsp_hw eq "$(derived_adsp 2800)"
  AR "解耦已重建：vbat_uv = 2800" vbat eq 2800
  AR "service.sh 残留进程 = 0" svc_procs eq 0
  AR "内核模块唯一" mods eq 1
  case_end; }

#CASE T9.3|并发竞态（3×service.sh + action.sh）→ 收敛且状态自洽
t_T9_3() { want T9.3 || return 0; case_begin T9.3 "并发竞态 -> 收敛且自洽"
  ensure_decouple 2800
  local out; out="$(sh_dev "$DEV_DIR/concurrent.sh")"
  race_snap || { bad "race_snap 失败"; case_end; return; }
  AR "并发结束后 service.sh 残留 = 0" svc_procs eq 0
  AR "并发结束后 action.sh 残留 = 0" action_procs eq 0
  AR "内核模块仍唯一" mods eq 1
  # 终态必须【自洽】：skip 存在 => 三项全等于原厂值且不绑定；skip 不存在 => 解耦三件套
  local org
  if [ "${R[skip]}" = "yes" ]; then
    snap && assert_factory_completed || { case_end; return; }
    org="${S[restore_target]}"
    AR "skip 态自洽：target=本次实时恢复目标" target eq "$org"
    AR "skip 态自洽：vbat=target" vbat eq "$org"
    AR "skip 态自洽：ADSP 硬件=target" adsp_hw eq "$org"
    AR "skip 态自洽：未绑定 capacity" bind eq 0
  else
    AR "解耦态自洽：target=2800" target eq 2800
    AR "解耦态自洽：ADSP=派生值" adsp_hw eq "$(derived_adsp 2800)"
  fi
  case_end; }

# ============================================================
# T10 组：标准启动路线专属（KSU 在 init_boot，随 boot 加载）
#   与越狱路线【本质不同】的三件事，都在这里断言：
#     1) post-fs-data.sh 会执行（越狱路线根本不跑这个阶段）
#     2) uv_dev 由【驱动开机 vote】自动捕获 → 不需要模块主动触发 deep_dischg
#     3) capacity 绑定在当前（全局）命名空间完成 → 不需要 nsenter -t 1 -m
#   越狱路线下本组整体 SKIP（route_gate 判 std）。
#   位置：排在所有用例最前 —— T10.3 的「无主动捕获」必须在本套用例动过状态之前采样。
# ============================================================

#CASE T10.1|启动路线 = 标准启动（KSU 随 boot 加载）|std
t_T10_1() { want T10.1 || return 0; case_begin T10.1 "启动路线 = 标准启动"
  refresh_route || { bad "route.sh 采集失败"; case_end; return; }
  AD "路线判定 = standard" boot_route eq standard
  # 判定来源可信性：dmesg（本次内核会话，最强）或 log 且日志是本次开机写的
  #   （2026-10-05 修正：此前断言 route_src == log，是把旧的优先级写进了断言）
  if [ "${DV[route_src]:-?}" = dmesg ]; then
    ok "判定来源 = dmesg（本次内核会话，最强证据）"; CASE_ASSERTS+=("PASS|判定来源可信|route_src|dmesg|dmesg 或 log+fresh")
  elif [ "${DV[route_src]:-?}" = log ] && [ "${DV[log_fresh]:-no}" = yes ]; then
    ok "判定来源 = log（且日志 mtime ≥ 开机时刻）"; CASE_ASSERTS+=("PASS|判定来源可信|route_src|log|dmesg 或 log+fresh")
  else
    bad "判定来源不可信：route_src=${DV[route_src]:-?} log_fresh=${DV[log_fresh]:-?}"
    CASE_ASSERTS+=("FAIL|判定来源可信|route_src|${DV[route_src]:-?}|dmesg 或 log+fresh")
  fi
  AD "KSU 模块已加载（/proc/modules）" ksu_loaded eq 1
  case_end; }

#CASE T10.2|post-fs-data 阶段完成（脚本已跑 + 模块已加载）|std
t_T10_2() { want T10.2 || return 0; case_begin T10.2 "post-fs-data 阶段完成"
  AD "本次开机跑过 post-fs-data.sh" pfd_current eq yes
  AD "post-fs-data insmod rc=0" pfd_insmod eq ok
  snap; A "模块已加载" module_loaded eq 1
  case_end; }

#CASE T10.3|uv_dev 可用（捕获方式记录在案）|std
t_T10_3() { want T10.3 || return 0; case_begin T10.3 "uv_dev 可用（捕获方式记录）"
  refresh_route
  local exp; exp="$(derived_adsp 2800)"
  ensure_decouple 2800
  snap; A "adsp_read = $exp（读得到 = uv_dev 已捕获）" adsp_read eq "$exp"
  # ⚠️ 这里【刻意不】断言「无主动捕获」——2026-10-04 22:28 实测教训：
  #   KSU 软重启会重跑 post-fs-data（模块重新 insmod），但【驱动开机 vote 早在真开机时就发生过了】
  #   → 此场景下模块走「主动触发 deep_dischg」兜底是【设计内正确行为】，不是缺陷。
  #   驱动开机 vote 这条路径由 T10.5（真硬重启，条件受控）严格验证。
  say "    本次开机捕获方式：active_cap=${DV[active_cap]:-?}（no=驱动开机 vote；yes=模块主动兜底）"
  case_end; }

#CASE T10.4|capacity 绑定在当前（全局）命名空间生效|std
t_T10_4() { want T10.4 || return 0; case_begin T10.4 "绑定在当前命名空间生效（未走 nsenter）"
  refresh_route
  AD "bind 方式 = 当前命名空间" bind_mode eq current
  snap; A "bind 层数 >= 1" bind_layers ge 1
  A "capacity == chip_soc" capacity eq "${S[chip_soc]:-?}"
  case_end; }

#CASE T10.5|标准启动 + 硬重启（不注入）→ 解耦保持|std,reboot
t_T10_5() { want T10.5 || return 0; case_begin T10.5 "硬重启（标准启动，不注入 ghostlock）"
  [ "$NO_REBOOT" = 1 ] && { skip_case T10.5 x "--no-reboot"; return; }
  ensure_decouple 2800
  hard_reboot_plain || { skip_case T10.5 x "硬重启失败/开机后 su 不可用"; return; }
  refresh_route
  AD "重启后仍是标准启动" boot_route eq standard
  AD "重启后 post-fs-data 仍执行" pfd_current eq yes
  # ★ 标准启动路线的签名行为：真·冷启动下，uv_dev 由【驱动开机 vote】自动捕获。
  #   必须在本模块已安装的前提下硬重启才成立（软重启/刚装完模块时驱动 vote 早已发生，
  #   那时模块主动兜底才是对的 —— 见 T10.3 的注释）
  AD "冷启动：无「主动触发 deep_dischg」（驱动 vote 自动捕获）" active_cap eq no
  wait_key param_target 2800 15
  local exp; exp="$(derived_adsp 2800)"
  snap
  A "uv_target_mv = 2800" param_target eq 2800
  A "vbat_uv = 2800（hook 已生效）" vbat_uv eq 2800
  A "adsp_read = $exp" adsp_read eq "$exp"
  A "bind 生效" bind_layers ge 1
  case_end; }

# ---------------- 报告 ----------------
report() {
  local json="$OUT/report.json" md="$OUT/report.md" jl="$OUT/report.jsonl"
  printf '%s\n' "${JSON_ROWS[@]:-}" > "$jl"
  {
    echo "{"
    echo "  \"ts\": \"$TS\","
    echo "  \"device\": \"$DEV\","
    echo "  \"device_model\": \"${DV[dev_model]:-?}\","
    echo "  \"device_rom\": \"${DV[dev_rom]:-?}\","
    echo "  \"device_android\": \"${DV[dev_android]:-?}\","
    echo "  \"jailbreak_profile\": \"${DV[dev_jbprofile_rel]:-}\","
    echo "  \"jailbreak_profile_md5\": \"${DV[dev_jbprofile_md5]:-}\"",
    echo "  \"device_oplusrom\": \"${DV[dev_oplusrom]:-?}\","
    echo "  \"device_kernel\": \"${DV[dev_kernel]:-?}\","
    echo "  \"device_modko_md5\": \"${DV[dev_modko]:-?}\","
    echo "  \"device_chgko_md5\": \"${DV[dev_chgko]:-?}\","
    echo "  \"device_slot\": \"${DV[dev_slot]:-?}\","
    echo "  \"device_vbstate\": \"${DV[dev_vbstate]:-?}\","
    echo "  \"driver_profile\": \"${DV[dev_profile]:-?}\","
    echo "  \"driver_profile_src\": \"${DV[dev_profile_src]:-?}\","
    echo "  \"driver_hooks\": \"${DV[dev_hooks]:-}\"",
    echo "  \"boot_route\": \"${DV[boot_route]:-unknown}\","
    echo "  \"route_src\": \"${DV[route_src]:-?}\","
    echo "  \"route_evidence\": \"${DV[route_evidence]//\"/}\","
    echo "  \"with_reboot\": $WITH_REBOOT,"
    echo "  \"no_reboot\": $NO_REBOOT,"
    echo "  \"tested_zip_sha256\": \"${TESTED_SHA256:-}\","
    echo "  \"runner_sha256\": \"$RUNNER_SHA256\","
    echo "  \"floor\": $FLOOR,"
    echo "  \"pass\": $PASS, \"fail\": $FAIL, \"skip\": $SKIP,"
    echo "  \"asserts\": ["
    local first=1 r
    for r in "${JSON_ROWS[@]:-}"; do
      [ -z "$r" ] && continue
      [ $first = 1 ] && first=0 || echo ","
      printf '    %s' "$r"
    done
    echo ""
    echo "  ]"
    echo "}"
  } > "$json"
  {
    echo "# uv2800 回归测试报告 $TS"
    echo ""
    echo "- 设备：\`$DEV\`"
    echo "- 机型 / ROM：\`${DV[dev_model]:-?}\` / \`${DV[dev_rom]:-?}\`（oplusrom \`${DV[dev_oplusrom]:-?}\`，Android ${DV[dev_android]:-?}）"
    echo "- 内核：\`${DV[dev_kernel]:-?}\`"
    echo "- 设备上模块 .ko md5：\`${DV[dev_modko]:-?}\`"
    echo "- **启动路线：\`${DV[boot_route]:-unknown}\`**（判定来源 \`${DV[route_src]:-?}\`，需重启用例 \`--with-reboot\`=$WITH_REBOOT）"
    echo "  - 判据：\`${DV[route_evidence]:-?}\`"
    echo "- 厂商驱动 oplus_chg_v2.ko md5：\`${DV[dev_chgko]:-?}\`"
    echo "- 模块自报 profile：\`${DV[dev_profile]:-?}\` ${DV[dev_hooks]:-}（dmesg 被冲掉时记为 ?）"
    echo "- 槽位 / 校验状态：\`${DV[dev_slot]:-?}\` / \`${DV[dev_vbstate]:-?}\`"
    echo "- **被测构建：v${TESTED_VER:-?}**  \`$TESTED_ZIP\`"
    echo "- 构建 md5：\`${TESTED_MD5:-?}\`"
    echo "- FLOOR：\`$FLOOR\`（ADSP 派生用）"
    echo "- 结果：**PASS $PASS · FAIL $FAIL · SKIP $SKIP**"
    echo ""
    echo "| case | 名称 | 结果 |"
    echo "|---|---|---|"
    printf '%s\n' "${JSON_ROWS[@]:-}" | sed -n 's/.*"case":"\([^"]*\)","name":"\([^"]*\)","result":"\([^"]*\)".*/\1|\2|\3/p' | sort -u | awk -F'|' '{printf "| %s | %s | %s |\n",$1,$2,$3}'
    echo ""
    echo "失败明细见 \`report.jsonl\` 与 \`logs/\`。"
  } > "$md"
  say ""
  say "════════════════════════════════════════"
  say "  PASS $PASS · FAIL $FAIL · SKIP $SKIP"
  say "  报告：$md"
  say "════════════════════════════════════════"
  [ "$FAIL" -gt 0 ] && return 1 || return 0
}

# ---------------- 主流程 ----------------
# 身份匹配后才载入历史 PASS；旧报告缺少构建/测试脚本指纹时重新运行。
RESUME_IDS=""
RUNNER_SHA256="$(sha256sum "$SELF" "$DEV_DIR"/*.sh "$HERE/host/resume.py" | sha256sum | cut -d' ' -f1)"
load_resume() {
  [ "$RESUME" = 1 ] || return 0
  RESUME_IDS="$(python3 "$HERE/host/resume.py" "$HERE/results" "$OUT" \
    "$DEV" "${DV[dev_model]:-?}" "${DV[dev_rom]:-?}" "${DV[dev_kernel]:-?}" \
    "${DV[dev_chgko]:-?}" "$ROUTE" "${TESTED_SHA256:-}" "$RUNNER_SHA256" \
    "$FLOOR" "$WITH_REBOOT" "$NO_REBOOT")" || { RESUME_IDS=""; warn "历史报告读取失败，全部重跑"; }
  [ -z "$RESUME_IDS" ] || say "resume：复用同环境、同构建的 PASS：$RESUME_IDS"
}
run_case() {
  local id="$1"; shift
  if [ "$WITH_DT" != 1 ] || [[ "$id" != TD.* ]]; then want "$id" || return 0; fi
  if [ -n "$RESUME_IDS" ] && [[ " $RESUME_IDS " == *" $id "* ]]; then
    say ""; say "── $id  （resume：上次已 PASS，跳过）"
    SKIP=$((SKIP+1))
    JSON_ROWS+=("{\"case\":\"$id\",\"name\":\"(resumed)\",\"result\":\"SKIP\",\"assert\":\"resume: 上次已 PASS\"}")
    return 0
  fi
  # 路线闸门：不适用的用例直接记 SKIP（附原因），不进 case 函数
  local why; why="$(route_gate "$id")"
  if [ -n "$why" ]; then skip_case "$id" "${CNAME[$id]:-x}" "$why"; return 0; fi
  "$@"
}

# ============================================================
# 可选组 TD：uv_dt_orig() 失败注入（宿主侧，**默认不跑**）
#   开启：./run.sh --with-dt   |   UV_DT=1 ./run.sh   |   ./run.sh TD
#   资产：自动化测试矩阵/dt_inject/（runner / 语料生成器 / base 基线 / 哨兵）
#   设计说明与 13 例清单：dt_inject/README.md（含"假绿"教训与哨兵意义）
#   ⚠️ 默认不参与计数，因此**不影响任何兼容性结论**（开启时才出现在报告里）。
# ============================================================
#CASE TD.1|uv_dt_orig 失败注入（宿主，无需设备）|opt
t_TD_1() { { [ "$WITH_DT" = 1 ] || want TD.1; } || return 0; case_begin TD.1 "uv_dt_orig 失败注入（宿主，无需设备）"
  local d="$HERE/dt_inject" out rc
  out="$(python3 "$d/run_cases.py" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$OUT/logs/TD.1.txt"
  if [ "$rc" -eq 0 ]; then
    CASE_ASSERTS+=("13/13 断言通过（明细 logs/TD.1.txt）")
  else
    CASE_FAILED=1; CASE_ASSERTS+=("有用例未达预期（明细 logs/TD.1.txt）")
  fi
  case_end; }

#CASE TD.2|uv_dt_orig 哨兵自测（验证测试本身有牙）|opt
t_TD_2() { { [ "$WITH_DT" = 1 ] || want TD.2; } || return 0; case_begin TD.2 "uv_dt_orig 哨兵自测（注入已删除的 v0_order）"
  local d="$HERE/dt_inject" v out rc
  python3 "$d/mk_v0order_variant.py" > "$OUT/logs/TD.2.mk.txt" 2>&1
  v=/tmp/log_with_v0order.sh
  if [ ! -f "$v" ]; then
    CASE_FAILED=1; CASE_ASSERTS+=("无法生成变体（见 logs/TD.2.mk.txt）"); case_end; return 0
  fi
  out="$(UV_DT_LOG="$v" python3 "$d/run_cases.py" v0drop_ok 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$OUT/logs/TD.2.txt"
  if [ "$rc" -ne 0 ]; then
    CASE_ASSERTS+=("注入 v0_order 后 v0drop_ok 如期 FAIL ⇒ 哨兵有牙")
  else
    CASE_FAILED=1; CASE_ASSERTS+=("注入后仍 PASS ⇒ 哨兵已失效（见 logs/TD.2.txt）")
  fi
  case_end; }

main() {
  resolve_dev || { echo "✗ 找不到 adb 设备（检查 USB / UV_SERIAL）"; exit 2; }
  say "设备: $DEV"
  say "输出: $OUT"
  # 目录必须以 shell 身份创建（root 拥有的目录会导致 adb push 权限不足）
  adb -s "$DEV" shell "mkdir -p $DEV_TMP" >/dev/null 2>&1
  adb -s "$DEV" shell "su -c 'chmod 777 $DEV_TMP'" >/dev/null 2>&1
  local f pushfail=0
  for f in snap.sh apply.sh logtail.sh softreboot.sh touchskip.sh rmmod_only.sh devver.sh racesnap.sh concurrent.sh route.sh; do
    if ! timeout 30 adb -s "$DEV" push "$DEV_DIR/$f" "$DEV_TMP/$f" >/dev/null 2>&1; then
      echo "✗ 推送失败: $f → $DEV_TMP"; pushfail=1
    fi
  done
  [ "$pushfail" = 1 ] && { echo "✗ 设备脚本推送失败，终止"; exit 2; }
  PUSHED=1
  echo "设备脚本已就绪: $DEV_TMP"
  ensure_module

  # P2-14：采集设备/内核/驱动版本戳（写入 report.json / report.md）
  local _dv
  _dv="$(sh_dev "$DEV_DIR/devver.sh" 2>/dev/null)"
  if [ -n "$_dv" ]; then
    while IFS='=' read -r _k _v; do
      [ -n "$_k" ] && DV["$_k"]="$_v"
    done <<< "$_dv"
    say "设备版本戳: ${DV[dev_model]:-?} / ${DV[dev_rom]:-?} / ${DV[dev_kernel]:-?}"
  else
    warn "版本戳采集失败（devver.sh），报告将显示 ?"
  fi

  # ---- 启动路线判定（决定跑哪一支用例集）----
  refresh_route || { echo "✗ 启动路线采集失败，终止"; exit 2; }
  say "启动路线: $ROUTE（来源 $ROUTE_SRC）"
  [ -n "${DV[route_evidence]:-}" ] && say "  判据: ${DV[route_evidence]}"
  case "$ROUTE" in
    standard|late-load) ;;
    unknown)
      echo "✗ 无法判定启动路线：模块日志里既无 post-fs-data 也无 KSU_LATE_LOAD=1"
      echo "  → 显式指定：UV_ROUTE=standard ./run.sh   或   UV_ROUTE=late-load ./run.sh"
      exit 2 ;;
    *)
      echo "✗ 未知启动路线：'$ROUTE'（只接受 standard / late-load）"; exit 2 ;;
  esac
  if [ "$ROUTE" = standard ]; then
    if [ "$WITH_REBOOT" = 1 ]; then say "  用例集：标准启动分支（含需重启用例）"
    else say "  用例集：标准启动分支（需重启用例默认跳过，加 --with-reboot 启用）"; fi
  else
    say "  用例集：late-load 越狱全量分支"
  fi

  load_resume

  # T10 组最先运行。
  run_case T10.1 t_T10_1; run_case T10.2 t_T10_2; run_case T10.3 t_T10_3; run_case T10.4 t_T10_4
  run_case T0.1 t_T0_1; run_case T0.2 t_T0_2
  run_case T1.1 t_T1_1; run_case T1.2 t_T1_2; run_case T1.3 t_T1_3; run_case T1.4 t_T1_4; run_case T1.5 t_T1_5
  run_case T2.1 t_T2_1; run_case T2.2 t_T2_2; run_case T2.3 t_T2_3; run_case T2.4 t_T2_4; run_case T2.5 t_T2_5
  run_case T3.1 t_T3_1; run_case T3.2 t_T3_2
  run_case T4.1 t_T4_1; run_case T4.2 t_T4_2
  run_case T5.1 t_T5_1
  run_case T6.1 t_T6_1; run_case T6.2 t_T6_2; run_case T6.3 t_T6_3; run_case T6.4 t_T6_4; run_case T6.5 t_T6_5; run_case T6.6 t_T6_6
  run_case T7.2 t_T7_2
  run_case T8.1 t_T8_1
  run_case T9.1 t_T9_1; run_case T9.2 t_T9_2; run_case T9.3 t_T9_3
  run_case T10.5 t_T10_5   # 会硬重启，放最后

  # ---- 可选组 TD（宿主侧，无需设备；默认不跑，开启方式见文件头）----
  if [ "$WITH_DT" = 1 ] || printf '%s\n' "${WANT[@]:-}" | grep -q '^TD'; then
    run_case TD.1 t_TD_1; run_case TD.2 t_TD_2
  fi

  say ""
  say "收尾：恢复解耦态 2800"
  ensure_decouple 2800 >/dev/null 2>&1
  snap >/dev/null 2>&1 && say "  最终：target=${S[param_target]:-?} vbat_uv=${S[vbat_uv]:-?} adsp=${S[adsp_read]:-?} skip=${S[skip]:-?}"
  report
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
