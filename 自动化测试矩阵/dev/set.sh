#!/system/bin/sh
# 用法: set.sh <skip:yes|no> <orig:数字|del> [nrs] [target] [origstate] [delxml]
B=/data/adb/uv2800_backup; mkdir -p $B
[ "$1" = yes ] && touch $B/skip || rm -f $B/skip
case "$2" in del) rm -f $B/adsp_orig.txt ;; *) echo "$2" > $B/adsp_orig.txt ;; esac
[ "${3:-no}" = yes ] && touch $B/no_real_soc || rm -f $B/no_real_soc
[ -n "${4:-}" ] && echo "$4" > $B/target_mv
[ -n "${5:-}" ] && echo "$5" > $B/orig_state
[ "${6:-no}" = yes ] && rm -f $B/devicepolicy_orig.xml
echo set-ok