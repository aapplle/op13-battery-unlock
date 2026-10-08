#!/system/bin/sh
# uv2800 测试：状态设置器
#   apply.sh decouple [V_s]   解耦态（rm skip + 可选设 target_mv + 跑 service.sh）
#   apply.sh factory          出厂态（action.sh --restore-only，不安排卸载）
#   apply.sh target <V_s>     只改 target_mv 并重跑 service.sh
#   apply.sh reset_orig       删除 adsp_orig.txt / adsp_state / target_mv（回到首次安装状态）
#   apply.sh pollute_orig <v> 污染 adsp_orig.txt（边界测试）
BK=/data/adb/uv2800_backup
M=/data/adb/modules/uv2800
P=/sys/module/uv2800/parameters

finish() { echo "rc=$1"; exit "$1"; }

case "${1:-}" in
  decouple)
    rm -f "$BK/skip" || finish "$?"
    if [ -n "${2:-}" ]; then echo "$2" > "$BK/target_mv" || finish "$?"; fi
    sh "$M/service.sh" > /data/local/tmp/uvtest/last_service.log 2>&1
    finish "$?"
    ;;
  factory)
    sh "$M/action.sh" --restore-only > /data/local/tmp/uvtest/last_action.log 2>&1
    finish "$?"
    ;;
  target)
    [ -n "${2:-}" ] || finish 2
    echo "$2" > "$BK/target_mv" || finish "$?"
    sh "$M/service.sh" > /data/local/tmp/uvtest/last_service.log 2>&1
    finish "$?"
    ;;
  reset_orig)
    rm -f "$BK/adsp_orig.txt" "$BK/adsp_state" "$BK/target_mv" "$BK/skip"
    finish "$?"
    ;;
  pollute_orig)
    [ -n "${2:-}" ] || finish 2
    echo "$2" > "$BK/adsp_orig.txt"
    finish "$?"
    ;;
  *) echo "usage: $0 {decouple|factory|target|reset_orig|pollute_orig}"; exit 2 ;;
esac
