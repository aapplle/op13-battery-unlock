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

case "$1" in
  decouple)
    rm -f $BK/skip
    [ -n "${2:-}" ] && echo "$2" > $BK/target_mv
    sh $M/service.sh > /data/local/tmp/uvtest/last_service.log 2>&1
    echo "rc=$?"
    ;;
  factory)
    sh $M/action.sh --restore-only > /data/local/tmp/uvtest/last_action.log 2>&1
    echo "rc=$?"
    ;;
  target)
    echo "$2" > $BK/target_mv
    sh $M/service.sh > /data/local/tmp/uvtest/last_service.log 2>&1
    echo "rc=$?"
    ;;
  reset_orig)
    rm -f $BK/adsp_orig.txt $BK/adsp_state $BK/target_mv $BK/skip
    echo "rc=0"
    ;;
  pollute_orig)
    echo "$2" > $BK/adsp_orig.txt
    echo "rc=0"
    ;;
  *) echo "usage: $0 {decouple|factory|target|reset_orig|pollute_orig}"; exit 2 ;;
esac
