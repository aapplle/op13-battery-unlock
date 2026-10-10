#!/system/bin/sh
# ============================================================
# uv2800 测试：启动路线自动判定（标准启动 / late-load 越狱）
#   run.sh 采集本脚本输出 → 决定跑哪一支用例集（见 run.sh 里 #CASE 的第三列）
#
#   【判据】只认两个「只可能由 KernelSU 自己产生」的标记：
#     A) "post-fs-data.sh 开始"  —— 只有标准启动（KSU 随 boot 加载）才会跑该阶段
#     B) "KSU_LATE_LOAD=1"      —— 只有 late-load（越狱注入）才会带这个环境变量
#   取 A / B 中【行号更大】的那个 = 最近一次开机所处路线。
#
#   ⚠️【不能】用 "KSU_LATE_LOAD= 空" 判标准启动：
#     apply.sh 与各用例会以主机身份 `sh service.sh`，那次的 KSU_LATE_LOAD 同样是空，
#     会把越狱路线误判成标准启动（实测踩过）。
#
#   ⚠️【必须先确认标记属于本次开机】：见下方第 3 步的三级判定（dmesg 优先）
#
#   ⚠️【不能】把 dmesg 当唯一依据：
#     本机内核环形缓冲约 10 分钟即被冲掉（实测 uptime 11min 时 [4.2s] 之前的行
#     已全部丢失，而 post-fs-data 跑在 ~4.0s）。故主依据取
#     $BK/uv2800.log（跨启动持久、含 KSU_LATE_LOAD 原值），dmesg 仅兜底。
# ============================================================
BK=/data/adb/uv2800_backup
L=$BK/uv2800.log

num() { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
lastn() { grep -n "$2" "$1" 2>/dev/null | tail -1 | cut -d: -f1; }
lastl() { grep -n "$2" "$1" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d '\r' | cut -c1-140; }

# ---- 1) 两个 KSU 专属标记的最后出现行号 ----
n_pfd=$(num "$(lastn "$L" 'post-fs-data.sh 开始')")
n_late=$(num "$(lastn "$L" 'KSU_LATE_LOAD=1')")
src=none
ev_pfd=$(lastl "$L" 'post-fs-data.sh 开始')
ev_late=$(lastl "$L" 'KSU_LATE_LOAD=1')

# ---- 3) 关键：判断日志里的标记是不是【本次开机】写的 ----
#   背景（2026-10-05 实测教训）：模块被卸载/刚刷机时，uv2800.log 里只有【上次开机】的
#   旧标记，若直接比较行号会把标准启动误判成 late-load —— 结果跑了错误的分支。
#
#   三级判定：
#     ① dmesg 命中 → 强证据。dmesg 是【本次内核会话】的、且天然按时间排序，
#        软重启也不会清空（新行排在旧行之后），所以「较晚出现者」= 本次路线。
#     ② dmesg 没命中，但日志文件 mtime ≥ 开机时刻 → 说明本次开机写过日志，
#        用日志行号比较（弱证据，route_src=log）。
#     ③ 都不满足 → unknown（标记全是上一轮开机的残留），由 run.sh 要求显式指定路线。
now=$(date +%s)
up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
case "${up:-}" in ''|*[!0-9]*) up=0 ;; esac
boot_t=$((now - up))
lm=0
if [ -f "$L" ]; then
    lm=$(stat -c %Y "$L" 2>/dev/null | tr -d ' ')
    case "${lm:-}" in ''|*[!0-9]*) lm=0 ;; esac
fi
if [ "$lm" -ge $((boot_t - 5)) ] && [ "$lm" -gt 0 ]; then log_fresh=yes; else log_fresh=no; fi

d_n_pfd=0; d_n_late=0
if command -v dmesg >/dev/null 2>&1; then
    d_n_pfd=$(dmesg 2>/dev/null | grep -n 'post-fs-data.sh 开始' | tail -1 | cut -d: -f1)
    d_n_late=$(dmesg 2>/dev/null | grep -n 'KSU_LATE_LOAD=1' | tail -1 | cut -d: -f1)
    case "${d_n_pfd:-}" in ''|*[!0-9]*) d_n_pfd=0 ;; esac
    case "${d_n_late:-}" in ''|*[!0-9]*) d_n_late=0 ;; esac
fi

route=unknown; ev=""
if [ "$d_n_pfd" -gt 0 ] || [ "$d_n_late" -gt 0 ]; then
    src=dmesg
    if [ "$d_n_late" -gt "$d_n_pfd" ]; then
        route=late-load; ev=$(dmesg 2>/dev/null | grep 'KSU_LATE_LOAD=1' | tail -1 | cut -c1-140)
    else
        route=standard;  ev=$(dmesg 2>/dev/null | grep 'post-fs-data.sh 开始' | tail -1 | cut -c1-140)
    fi
elif [ "$log_fresh" = yes ] && { [ "$n_pfd" -gt 0 ] || [ "$n_late" -gt 0 ]; }; then
    src=log
    if [ "$n_late" -gt "$n_pfd" ]; then route=late-load; ev="$ev_late"
    else                              route=standard;  ev="$ev_pfd"; fi
fi

# ---- 4) 本次开机段（从 boot 锚点到最后一行）内的行为证据 ----
anchor=$n_pfd
[ "$n_late" -gt "$anchor" ] && anchor=$n_late
[ "$anchor" -gt 0 ] || anchor=1
seg=$(tail -n +"$anchor" "$L" 2>/dev/null)

ac=$(printf '%s' "$seg" | grep -c '主动触发 deep_dischg' 2>/dev/null)
[ "$(num "$ac")" -gt 0 ] && active_cap=yes || active_cap=no

n_cur=$(num "$(printf '%s' "$seg" | grep -n '当前命名空间' | tail -1 | cut -d: -f1)")
n_nse=$(num "$(printf '%s' "$seg" | grep -n 'nsenter' | tail -1 | cut -d: -f1)")
if [ "$n_cur" = 0 ] && [ "$n_nse" = 0 ]; then bind_mode=none
elif [ "$n_nse" -gt "$n_cur" ]; then bind_mode=nsenter
else bind_mode=current; fi

if [ "$n_pfd" -gt 0 ]; then
    pseg=$(tail -n +"$n_pfd" "$L" 2>/dev/null)
    case "$pseg" in
        # v10 记 "insmod rc=0"；v11 起记 "insmod 成功"（06ad948 改的文案，
        # route.sh 未跟着改 → ok 分支自 v11 起不可达，T10.2 必失败）。
        *'post-fs-data insmod rc=0'*|*'post-fs-data insmod 成功'*)     pfd_insmod=ok ;;
        *'模块已在内存，跳过 insmod'*)     pfd_insmod=skip ;;
        *)                                pfd_insmod=? ;;
    esac
else
    pfd_insmod=?
fi

if [ "$n_pfd" -gt "$n_late" ]; then pfd_current=yes; else pfd_current=no; fi

echo "boot_route=${route}"
echo "route_src=${src}"
echo "route_evidence=${ev}"
echo "route_n_pfd=${n_pfd}"
echo "route_n_late=${n_late}"
echo "log_fresh=${log_fresh}"
echo "log_mtime=${lm}"
echo "boot_time=${boot_t}"
echo "dmesg_pfd_n=${d_n_pfd}"
echo "dmesg_late_n=${d_n_late}"
echo "pfd_current=${pfd_current}"
echo "pfd_insmod=${pfd_insmod}"
echo "active_cap=${active_cap}"
echo "bind_mode=${bind_mode}"
echo "svc_late_env=$(printf '%s' "$(grep 'service.sh 开始（KSU_LATE_LOAD=' "$L" 2>/dev/null | tail -1)" | sed 's/.*KSU_LATE_LOAD=//; s/）.*//')"
echo "log_lines=$(wc -l < "$L" 2>/dev/null | tr -d ' ')"
# KSU 不建 /sys/module/kernelsu（实测），只认 /proc/modules
echo "ksu_loaded=$(grep -c '^kernelsu' /proc/modules 2>/dev/null)"
echo "uv_loaded=$([ -d /sys/module/uv2800 ] && echo 1 || echo 0)"
echo "uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
