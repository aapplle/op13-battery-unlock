#!/system/bin/sh
# ============================================================
# uv2800 测试：竞态/残留快照（T9 组用）
#   输出 key=value：模块唯一性 / 版本 / 残留进程 / 僵尸 / 状态一致性
#   用法（主机）：adb shell "su -c 'sh /data/local/tmp/uvtest/racesnap.sh'"
# ============================================================
BK=/data/adb/uv2800_backup
P=/sys/module/uv2800/parameters
B=/sys/class/oplus_chg/battery

g(){ v=$(cat "$1" 2>/dev/null | tr -d '[:space:]'); [ -z "$v" ] && v="?"; echo "$v"; }
f(){ [ -e "$1" ] && echo yes || echo no; }

echo "mods=$(lsmod 2>/dev/null | grep -c '^uv2800')"
echo "ko_md5=$(md5sum /data/adb/modules/uv2800/uv2800.ko 2>/dev/null | cut -c1-8)"

n=0; m=0; z=0; zz=0
for p in /proc/[0-9]*; do
  c=$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ')
  case "$c" in
    *uv2800/service.sh*) n=$((n+1)) ;;
    *uv2800/action.sh*)  m=$((m+1)) ;;
    *uv2800*)            z=$((z+1)) ;;
  esac
  st=$(awk '{print $3}' "$p/stat" 2>/dev/null)
  [ "$st" = "Z" ] && zz=$((zz+1))
done
echo "svc_procs=$n"
echo "action_procs=$m"
echo "uv_any_procs=$z"
echo "zombies=$zz"

echo "skip=$(f $BK/skip)"
echo "target=$(g $P/uv_target_mv)"
echo "adsp_mv=$(g $P/uv_adsp_mv)"
echo 1 > $P/adsp_read 2>/dev/null
echo "adsp_hw=$(g $P/adsp_read)"
echo "vbat=$(g $B/vbat_uv)"
echo "resume=$(g $P/resume)"
echo "bind=$(grep -c chip_soc /proc/self/mountinfo 2>/dev/null)"
echo "sysboot=$(getprop sys.boot_completed 2>/dev/null)"
