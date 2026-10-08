#!/system/bin/sh
# ============================================================
# uv2800 - 公共日志函数
#   被 service.sh / action.sh / post-fs-data.sh / uninstall.sh source
#
#   关键日志【三路输出】：
#     1) stdout        —— KernelSU 管理器里可见
#     2) /dev/kmsg     —— dmesg 可见，便于现场排查
#     3) $BK/uv2800.log —— 落盘到备份目录，【卸载不清除】，方便用户反馈
#
#   用法： uv_log "消息内容"
# ============================================================
UV_BK=/data/adb/uv2800_backup
UV_LOG="$UV_BK/uv2800.log"

# 固定 inode + 继承的文件描述符：进程退出后内核自动释放，不删除锁文件。
# BusyBox/Toybox 的 flock 不一定支持 -w，统一用 -n 做有界等待。
uv_lock() {
    mkdir -p "$UV_BK" || return 1
    exec 9>"$UV_BK/operation.lock" || return 1
    UV_FLOCK=""
    if command -v flock >/dev/null 2>&1; then
        UV_FLOCK=flock
    else
        for _ul_bin in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox busybox toybox; do
            command -v "$_ul_bin" >/dev/null 2>&1 || continue
            if "$_ul_bin" --list 2>/dev/null | grep -qx flock ||
               "$_ul_bin" 2>/dev/null | tr ' ,\t' '\n' | grep -qx flock; then
                UV_FLOCK=$_ul_bin
                break
            fi
        done
    fi
    if [ -z "$UV_FLOCK" ]; then
        uv_log "错误：找不到 flock，停止操作（需要 KernelSU BusyBox 或 Toybox flock）"
        return 1
    fi
    _ul_wait=0
    while [ "$_ul_wait" -lt 90 ]; do
        if [ "$UV_FLOCK" = flock ]; then
            flock -n 9 2>/dev/null && return 0
        else
            "$UV_FLOCK" flock -n 9 2>/dev/null && return 0
        fi
        sleep 1
        _ul_wait=$((_ul_wait+1))
    done
    uv_log "错误：等待其它模块操作结束超时（90s），本次未执行"
    return 1
}

# 成功仅指本次真实读取成功；历史 adsp_state 不是硬件状态的证明。
uv_read_adsp() {
    _ur_p=${1:-/sys/module/uv2800/parameters}
    echo 1 > "$_ur_p/adsp_read" 2>/dev/null || return 1
    _ur_v=$(cat "$_ur_p/adsp_read" 2>/dev/null) || return 1
    case "$_ur_v" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_ur_v" -ge 2000 ] 2>/dev/null && [ "$_ur_v" -le 5000 ] 2>/dev/null || return 1
    echo "$_ur_v"
}

uv_set_targets() {
    _ut_shutdown=$1; _ut_adsp=$2
    _ut_p=${3:-/sys/module/uv2800/parameters}
    echo "$_ut_shutdown" > "$_ut_p/uv_target_mv" 2>/dev/null || return 1
    echo "$_ut_adsp" > "$_ut_p/uv_adsp_mv" 2>/dev/null || return 1
    echo 1 > "$_ut_p/resume" 2>/dev/null || return 1
    [ "$(cat "$_ut_p/uv_target_mv" 2>/dev/null)" = "$_ut_shutdown" ] &&
        [ "$(cat "$_ut_p/uv_adsp_mv" 2>/dev/null)" = "$_ut_adsp" ] &&
        [ "$(cat "$_ut_p/resume" 2>/dev/null)" = 0 ]
}

# 管理器卸载只是设置 remove；实际删除阶段不以 uninstall.sh 的退出码为闸门。
# 因而一键流程必须在任何恢复写入前撤销旧安排，成功验证后才重新安排。
uv_cancel_remove() {
    rm -f "$1/remove" /data/adb/modules_update/uv2800/remove || return 1
    [ ! -e "$1/remove" ] && [ ! -e /data/adb/modules_update/uv2800/remove ]
}

uv_find_ksud() {
    for _uk_bin in /data/adb/ksud /data/adb/ksu/bin/ksud; do
        if [ -x "$_uk_bin" ]; then echo "$_uk_bin"; return 0; fi
    done
    command -v ksud 2>/dev/null
}

uv_schedule_remove() {
    _us_dir=$1
    _us_ksud=$(uv_find_ksud) || _us_ksud=""
    if [ -n "$_us_ksud" ]; then
        "$_us_ksud" module uninstall uv2800 || return 1
    else
        # 本模块没有 initrc；官方 CLI 缺失时，使用公开的 remove 文件协议。
        touch "$_us_dir/remove" || return 1
    fi
    [ -f "$_us_dir/remove" ]
}

# 单芯 voltage_now 以微伏上报；返回本次确认可恢复的毫伏值。
uv_restore_voltage() {
    _uv_v=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null) || return 1
    case "$_uv_v" in ''|*[!0-9]*|??????????*) return 1 ;; esac
    [ "$_uv_v" -ge 2000000 ] 2>/dev/null && [ "$_uv_v" -le 5000000 ] 2>/dev/null || return 1
    _uv_v=$((_uv_v / 1000))
    [ "$_uv_v" -ge 3300 ] && [ "$_uv_v" -gt "$1" ] || return 1
    echo "$_uv_v"
}

uv_record_uninstall() {
    echo "$1" > "$UV_BK/uninstall_verified.tmp" &&
        mv -f "$UV_BK/uninstall_verified.tmp" "$UV_BK/uninstall_verified"
}

# 只供卸载时报告“上次验证”的证据，绝不替代在模块仍加载时的实时读取。
uv_previous_uninstall() {
    [ -f "$UV_BK/skip" ] && [ ! -e "$UV_BK/restore_pending" ] || return 1
    _up_v=$(cat "$UV_BK/uninstall_verified" 2>/dev/null) || return 1
    case "$_up_v" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_up_v" -ge 2000 ] 2>/dev/null && [ "$_up_v" -le 5000 ] 2>/dev/null || return 1
    [ "$(cat "$UV_BK/restore_target_mv" 2>/dev/null)" = "$_up_v" ] || return 1
    echo "$_up_v"
}

# umount 返回失败既可能是“未挂载”，也可能是权限/命名空间错误；单独只读确认。
uv_capacity_unbound() {
    for _um_file in /proc/1/mountinfo /proc/self/mountinfo; do
        [ -r "$_um_file" ] || return 1
        _um_info=$(cat "$_um_file" 2>/dev/null) || return 1
        [ -n "$_um_info" ] || return 1
        case "$_um_info" in *chip_soc*) return 1 ;; esac
    done
}

uv_log() {
    _m="uv2800: $*"
    echo "$_m"
    echo "$_m" > /dev/kmsg 2>/dev/null
    mkdir -p "$UV_BK" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S')] $_m" >> "$UV_LOG" 2>/dev/null
}

# 分隔线：每次脚本执行时打一条，便于把日志按运行分段
# 日志截断检查放在这里：每次运行只查一次 wc -l，避免 uv_log 每次调用都去数一遍
uv_log_sep() {
    # 超过 3000 行时保留后 1500 行，避免无限增长
    _n=$(wc -l < "$UV_LOG" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    if [ "$_n" -gt 3000 ]; then
        tail -1500 "$UV_LOG" > "$UV_LOG.tmp" 2>/dev/null && mv "$UV_LOG.tmp" "$UV_LOG" 2>/dev/null
    fi
    uv_log "---------- $1 ----------"
}

# ------------------------------------------------------------
# 把【内核模块自报的 profile】落盘
#   内核的 pr_info("uv2800: v11 ready, %d 个 hook, profile=[%s], ...") 只进 dmesg，
#   而本机内核环形缓冲约 10 分钟就被冲掉 —— 跨 ROM/内核做兼容性矩阵时，
#   "版本自适应选中了哪一支 profile" 就再也拿不到了。
#   本函数在 insmod 之后立刻抓一次，落到 $UV_LOG（持久）。
# ------------------------------------------------------------
uv_log_kver() {
    if ! command -v dmesg >/dev/null 2>&1; then
        uv_log "内核自报: (无 dmesg，跳过)"
        return 0
    fi
    _kv="$(dmesg 2>/dev/null | grep 'uv2800: v11 ready' | tail -1)"
    if [ -n "$_kv" ]; then
        uv_log "内核自报: ${_kv#*uv2800: }"
    else
        uv_log "内核自报: (未捕获到 'v11 ready'，insmod 可能失败)"
    fi
}

# ------------------------------------------------------------
# 公共工具：让内核模块在【没有任何 vote】的情况下捕获 uv_dev
#   原理：oplus_fg_set_batt_deep_dischg_count 入口的 x0 与 getter 需要的
#   device 【完全相同】，而它可被 userspace 触发 —— 同值写入即可。
#   本函数不产生任何语义变化（计数值不变），可反复调用。
#   调用后请重新读一次 adsp_read 确认。
# ------------------------------------------------------------
UV_DDRC=/sys/devices/virtual/oplus_chg/common/deep_dischg_counts
uv_capture_dev() {
    [ -w "$UV_DDRC" ] || return 1
    _cv=$(cat "$UV_DDRC" 2>/dev/null | tr -d "[:space:]")
    case "$_cv" in ''|*[!0-9]*) return 1 ;; esac
    echo "$_cv" > "$UV_DDRC" 2>/dev/null
    return 0
}
# ------------------------------------------------------------
# 公共工具：按【厂商标准】推算原厂终止电压（复刻驱动 ddrc_strategy 两维查表）
#   厂商链路（RE-B §12/§12.7 代码级定证；RE-D 第四批成对样本 18/18 实测自洽）：
#     ratio   = 10 × deep_dischg_counts / cc      （cc = GAUGE_ITEM_CC = 循环次数；
#                                                   仅 0<cc<5000 才做除法）
#     region  = ratio 与 oplus,ratio_range 升序比较，**≥ 即抬档**（驱动 b.hs）
#               0=min 1=low 2=mid_low 3=mid 4=mid_high 5=high
#     index_t = 温度与 oplus,temp_range 比较，**≤ 归下档**（驱动 b.le）
#               0=cold 1=cool 2=normal 3=warm
#     表行    = (f0 阈值, vbat0 关机电压, vbat1 终止电压, idx)，每行 4 个 u32（大端）
#     row k   = max{ i : max(0, row[i].f0 − count_cali) ≤ cc }（含等号；无满足取第 0 行）
#     输出    = row[k].vbat1（第 3 个字段 = 终止电压）
#
#   ⚠️ 终止电压【不能】从 deep_spec,term_coeff 查：那张表只决定驱动"用哪张 ddrc 表"，
#      不是电压来源，比较对象也应为 cc 而非 raw counts；
#      详见 文档/ISSUE-uv2800-DT兜底值错误(3250vs3350).md
#
#   ★ 失败语义：【宁失败，不猜值】。本函数算的是「原厂值」，一旦猜错会被写进电量计 IC
#     并被后续会话再次采纳（自我延续），因此任何结构异常都直接返回失败，由调用方决定
#     （service.sh / action.sh / uninstall.sh 都会退到各自的安全路径）。已识别的
#     "静默错值"场景：
#       · 行格式变 12 字节/行（合成夹具 Δ190mV；真机表改造后由 volt_range 拦下）
#       · 选到【诱饵节点】——顶层 oplus,mms_gauge/ddrc_strategy 与 silicon_p_770/ 下的
#         同名子树内容不同，实测偏差 0~100mV（v13 复核 C17 dtbo 为 0/20/40/50/90mV）
#       · counts 与 cc 同时为 0 —— 选行输入 cc 不可得（详见下方该分支注释）
#     这些都必须拦掉；【注意】上列数字中 12 字节/行与超大输入属合成注入，非真机故障。
#
#   结构自检（任一不过即 return 1）：
#     · 电池节点由 battery_type 权威定位；扫描兜底，与 battery_type 不一致时不猜
#     · oplus,ratio_range 恰好 5 项；oplus,temp_range 恰好 3 项
#     · 目标表存在，且字节数 % 16 == 0（每行 4×u32），行数 1~8
#     · 每行首字段 f0 满足 f0[0]==0 且非降
#     · 结果落在 [2900, 3500]（原厂终止电压的物理区间；超出即视为算错）
#
#   厂商回退（本实现只在"不可能算错"时才跟随）：温度读失败→index_t=3(warm)。
#   厂商在 ratio_range 读失败时回退 region=5(high)，本实现改为直接失败（无法区分
#   "节点缺失"与"解析失败"，猜档位会给出错值）。
#
#   用法：_orig=$(uv_dt_orig)     返回 mV（成功）/ 空串（失败）
#   自检：UV_DT_DEBUG=1 打印推导过程；UV_T_CNT/UV_T_CC/UV_T_CALI/UV_T_TEMP 可覆盖输入（单元验证用）
#         UV_T_BATT 可覆盖 battery_type；UV_T_DTB 可覆盖 DT 根（失败模式测试用）
# ------------------------------------------------------------
uv_dt_orig() {
    _dtb=${UV_T_DTB:-/sys/firmware/devicetree/base/soc/oplus,mms_gauge}

    # 统一失败出口：把原因**无条件**写到 stderr（不依赖 UV_DT_DEBUG）。
    # 本函数要在未知 ROM 上运行，"为什么算不出原厂值"是跨 ROM 排障的第一手信息。
    # 正常路径不会调用它（实测正常表 stderr 为空），因此不污染正常输出。
    _o_fail() {
        _om="[uv_dt_orig] FAIL $1 (batt=${_batt:-?} cnt=${_o_cnt:-?} cc=${_o_cc:-?} cali=${_o_cali:-?} temp=${_o_temp:-?})"
        echo "$_om" >&2
        # 同时落盘到模块日志。路径优先用 log.sh 的 $UV_LOG；万一未定义（log.sh 未 source、
        # 或被调用方清空）则回退到标准路径 —— 让"失败原因一定进得了日志"这条不变量**无条件**成立。
        # 【刻意不写 stdout】调用方用 _orig=$(uv_dt_orig) 捕获 stdout，写 stdout 会污染返回值。
        _ol="${UV_LOG:-/data/adb/uv2800_backup/uv2800.log}"
        mkdir -p "${_ol%/*}" 2>/dev/null
        echo "[$(date '+%m-%d %H:%M:%S')] uv2800: $_om" >> "$_ol" 2>/dev/null
        return 0
    }

    # 【节点定位】优先用 battery_type 权威定位；扫描仅作兜底。
    # 经验：ddrc_strategy 可能同时存在于顶层与电池子节点下（内容不同），
    # 取"第一个带该子树的节点"在多节点 ROM 上会静默选错表。
    _o_bt=${UV_T_BATT:-$(cat /sys/class/oplus_chg/battery/battery_type 2>/dev/null)}
    _batt=""
    if [ -n "$_o_bt" ] && [ -d "$_dtb/$_o_bt/ddrc_strategy" ]; then
        _batt=$_o_bt
    else
        for _d in "$_dtb"/*/; do
            [ -d "${_d}ddrc_strategy" ] || continue
            _batt=$(basename "$_d"); break
        done
        # battery_type 已知但对应节点不存在 → 说明扫描到的不是本机电池，不猜
        if [ -n "$_o_bt" ] && [ -n "$_batt" ] && [ "$_batt" != "$_o_bt" ]; then
            _o_fail "节点不匹配: battery_type=$_o_bt 扫描到=$_batt"
            return 1
        fi
    fi
    if [ -z "$_batt" ]; then
        _o_fail "未找到含 ddrc_strategy 的电池节点 (dtb=$_dtb)"
        return 1
    fi
    _ddrc="$_dtb/$_batt/ddrc_strategy"

    _o_cnt=$(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_counts 2>/dev/null)
    _o_cc=$(cat /sys/class/oplus_chg/battery/battery_cc 2>/dev/null)
    _o_cali=$(cat /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali 2>/dev/null)
    _o_temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    [ -n "$UV_T_CNT" ]  && _o_cnt=$UV_T_CNT
    [ -n "$UV_T_CC" ]   && _o_cc=$UV_T_CC
    [ -n "$UV_T_CALI" ] && _o_cali=$UV_T_CALI
    [ -n "$UV_T_TEMP" ] && _o_temp=$UV_T_TEMP
    case "$_o_cnt"  in ''|*[!0-9]*) _o_fail "counts 非数字: '$_o_cnt'"; return 1 ;; esac
    case "$_o_cc"   in ''|*[!0-9]*) _o_fail "cc 非数字: '$_o_cc'";       return 1 ;; esac
    # count_cali：节点【不存在】→ 按 0（厂商语义：该字段可选）；
    # 节点【存在】但读值非法 → 失败。实测 cali 取不同值可使结果相差 0~190mV，
    # 且各值都落在合法带内 —— 静默按 0 无法被结果区间检查发现，故必须区分这两种情况。
    if [ -e /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali ]; then
        case "$_o_cali" in
            ''|*[!0-9]*)
                _o_fail "count_cali 读值非法: '$_o_cali'（节点存在但不可解析）"
                return 1 ;;
        esac
    else
        _o_cali=0
    fi

    # 输入上界：超大数在 64 位 shell 上会溢出成负值，进而算出负 ratio → region 归 0 →
    # 静默给出带内错值（实测 UV_T_CNT=99999999999999999999 → ratio 为负 → 3060）。
    # 先用字符串长度拦一道，避免 shell 自身在超大数上溢出或报错。
    case "$_o_cnt"  in ??????????*) _o_fail "counts 超上界(≥10位): $_o_cnt";      return 1 ;; esac
    case "$_o_cc"   in ??????????*) _o_fail "cc 超上界(≥10位): $_o_cc";          return 1 ;; esac
    case "$_o_cali" in ??????????*) _o_fail "count_cali 超上界(≥10位): $_o_cali"; return 1 ;; esac
    if [ "$_o_cnt"  -gt 1000000 ]; then _o_fail "counts 超上界: $_o_cnt (max 1e6)";  return 1; fi
    if [ "$_o_cc"   -gt 1000000 ]; then _o_fail "cc 超上界: $_o_cc (max 1e6)";      return 1; fi
    if [ "$_o_cali" -gt 10000   ]; then _o_fail "count_cali 超上界: $_o_cali (max 1e4)"; return 1; fi

    # 读一串大端 u32（DT 属性即 BE u32 数组）
    _o_be32() {
        od -An -tx1 -v "$1" 2>/dev/null | tr -s ' \n' '\n' | grep -v '^$' | awk '
        function h2d(h,   i, c, d, v) {
            v = 0
            for (i = 1; i <= length(h); i++) {
                c = tolower(substr(h, i, 1)); d = index("0123456789abcdef", c) - 1
                if (d < 0) return -1
                v = v * 16 + d
            }
            return v
        }
        { b[n++] = $1 }
        END { o = ""; for (i = 0; i + 3 < n; i += 4) o = o h2d(b[i] b[i+1] b[i+2] b[i+3]) " "; print o }'
    }

    # 退化输入：counts 与 cc 同时为 0（新机 / 刚刷机 / 电量计未就绪）。
    # 【v13 更正】原注释称"厂商此时 ratio=100 → region5，与本实现 max 差 250mV" ——
    # 与本实现同源的厂商算式矛盾：厂商同样只在 0 < cc < 5000 时做除法，cc=0 时两边
    # 的 ratio 都是 10×counts = 0 → region 都是 min，不存在档位对撞。
    # 真正的风险是【选行输入 cc 不可得】：cc=0 更像"电量计尚未上报循环数"而非"真的
    # 0 次循环"，据此定行（thr ≤ 0 ⇒ 只取首行）无法确证本机真原厂值 ⇒ 宁失败不猜。
    if [ "$_o_cnt" -eq 0 ] && [ "$_o_cc" -eq 0 ]; then
        _o_fail "counts 与 cc 同时为 0，无法定档"
        return 1
    fi

    # ① ratio（厂商算式：0<cc<5000 才除）
    _o_ratio=$(( 10 * _o_cnt ))
    if [ "$_o_cc" -gt 0 ] && [ "$_o_cc" -lt 5000 ]; then
        _o_ratio=$(( 10 * _o_cnt / _o_cc ))
    fi

    # ② region：≥ 即抬档（含下不含上）
    # 档位表必须恰好 5 项。厂商在 ratio_range 读失败时回退 region=5(high)；
    # 但本实现无法区分"节点缺失"与"解析失败"，猜档位会静默给出错值 → 直接失败。
    _o_rrl=$(_o_be32 "$_ddrc/oplus,ratio_range")
    set -- $_o_rrl
    if [ $# -ne 5 ]; then
        _o_fail "ratio_range 项数=$#（期望 5）"
        return 1
    fi
    _o_region=0; _o_i=0
    for _o_b in $_o_rrl; do
        [ "$_o_ratio" -ge "$_o_b" ] && _o_region=$(( _o_i + 1 ))
        _o_i=$(( _o_i + 1 ))
    done
    case "$_o_region" in
        0) _o_rname=strategy_ratio_range_min ;;
        1) _o_rname=strategy_ratio_range_low ;;
        2) _o_rname=strategy_ratio_range_mid_low ;;
        3) _o_rname=strategy_ratio_range_mid ;;
        4) _o_rname=strategy_ratio_range_mid_high ;;
        *) _o_rname=strategy_ratio_range_high ;;
    esac

    # ③ index_t：≤ 归下档；温度缺失 → 3(warm)（照抄厂商）
    # 温度档必须恰好 3 项（两维查表的分档下限数）。
    # 注意：temp_range 元素是 u32，负值（如 -50）以补码存储（4294967246）。
    # mksh 32 位算术会自动折叠，但 64 位 shell（bash）需要显式转换。
    _o_trl=$(_o_be32 "$_ddrc/oplus,temp_range")
    set -- $_o_trl
    if [ $# -ne 3 ]; then
        _o_fail "temp_range 项数=$#（期望 3）"
        return 1
    fi
    _o_it=3
    case "$_o_temp" in
        ''|*[!0-9-]*) : ;;
        *)
            _o_j=0
            for _o_b in $_o_trl; do
                # 显式符号转换：>0x7FFFFFFF 视为负值
                if [ "$_o_b" -gt 2147483647 ] 2>/dev/null; then
                    _o_b=$(( _o_b - 4294967296 ))
                fi
                if [ "$_o_temp" -le "$_o_b" ]; then _o_it=$_o_j; break; fi
                _o_j=$(( _o_j + 1 ))
            done
            ;;
    esac
    case "$_o_it" in
        0) _o_tname=strategy_temp_cold ;;
        1) _o_tname=strategy_temp_cool ;;
        2) _o_tname=strategy_temp_normal ;;
        *) _o_tname=strategy_temp_warm ;;
    esac

    # ④ 选行并取第 3 个字段（vbat1 = 终止电压），带结构自检：
    #   字节数 % 16 == 0（每行 4×u32）、行数 1~8、f0[0]==0 且 f0 非降。
    #   实测过"行格式变 12 字节/行"会静默把 3250 算成 3060（Δ190mV），必须拦掉。
    _o_out=$(od -An -tx1 -v "$_ddrc/$_o_rname/$_o_tname" 2>/dev/null | tr -s ' \n' '\n' | grep -v '^$' | awk -v cc="$_o_cc" -v cali="$_o_cali" '
    function h2d(h,   i, c, d, v) {
        v = 0
        for (i = 1; i <= length(h); i++) {
            c = tolower(substr(h, i, 1)); d = index("0123456789abcdef", c) - 1
            if (d < 0) return -1
            v = v * 16 + d
        }
        return v
    }
    { b[n++] = $1 }
    END {
        if (n == 0)        { print "ERR empty"; exit }
        if (n % 16 != 0)   { print "ERR size";  exit }
        rows = n / 16
        if (rows < 1 || rows > 8) { print "ERR rows"; exit }
        first = -1; tgt = -1; prev = -1
        for (i = 0; i + 15 < n; i += 16) {
            f0 = h2d(b[i] b[i+1] b[i+2] b[i+3])
            v0 = h2d(b[i+4] b[i+5] b[i+6] b[i+7])
            v1 = h2d(b[i+8] b[i+9] b[i+10] b[i+11])
            if (f0 < 0 || v0 < 0 || v1 < 0) { print "ERR hex"; exit }
            # 【列语义】每一行的两个电压列都必须是 mV 量级：这两列是电压，不是计数/索引。
            # 这是最强的一条不变量：任何"行宽变化导致的重解析错位"都会把计数或索引
            # 错位读进电压列，几乎必然越界。区间取自 DT 语料实测范围（vbat0/vbat1 ∈ 2000~5000）。
            if (v0 < 2000 || v0 > 5000 || v1 < 2000 || v1 > 5000) { print "ERR volt_range"; exit }
            if (i == 0) { if (f0 != 0) { print "ERR f0_base"; exit } }
            else if (f0 < prev) { print "ERR f0_order"; exit }
            # 【v13 删除】此处原有「vbat0 列非降」自检（ERR v0_order）。删除理由：
            #   真实厂商表会【合法】违反它 —— 行 0 是 (f0=0, 高电压) 的基准记录，
            #   阶梯从行 1 重新起算，于是 v0 回落。实测 6 个 ROM 的 dtbo + 真机 dump
            #   按内容去重后共 81 张不同的表中，其余 8 条不变量全部通过，仅本条约 9 张(11%) 违反
            #   （如 min/normal = (0,3100,3100)(15,3000,3060)(500,3100,3100)...）。
            #   且驱动选行只用 f0 列、终止电压取第 3 列（vbat0 另投关机电压 votable），
            #   vbat0 单调性并非正确性前提 —— 误拒会让本可算出的原值变成硬失败。
            #   行宽错位改由上面的 volt_range 兜底：实测把真机表改成 12 B/行会被它拒绝
            #   （真实 f0 恒在 [0,2000]，误解析无法同时让两个电压列都落进 2000~5000）。
            prev = f0
            if (first < 0) first = v1
            thr = f0 - cali; if (thr < 0) thr = 0
            if (thr <= cc) tgt = v1
        }
        if (tgt < 0) tgt = first
        print "OK " tgt
    }')
    case "$_o_out" in
        OK\ *) _o_val=${_o_out#OK } ;;
        *)
            _o_fail "表自检 ${_o_out:-<空>} region=$_o_region index_t=$_o_it"
            return 1 ;;
    esac
    # 结果区间：原厂终止电压的物理区间（DT 表实测 3000~3350）。越界即视为算错。
    if [ "$_o_val" -lt 2900 ] || [ "$_o_val" -gt 3500 ]; then
        _o_fail "结果越界: $_o_val（期望 2900~3500）"
        return 1
    fi
    if [ "$UV_DT_DEBUG" = 1 ]; then
        echo "[uv_dt_orig] batt=$_batt cnt=$_o_cnt cc=$_o_cc cali=$_o_cali temp=${_o_temp:-NA} ratio=$_o_ratio region=$_o_region($_o_rname) index_t=$_o_it($_o_tname) -> $_o_val mV" >&2
    fi
    echo "$_o_val"
}
# 公共工具：解绑 chip_soc -> capacity 的 bind-mount
#   用法：uv_unbind_capacity [CAP] [CAPUE]
#   CAP 默认 /sys/class/power_supply/battery/capacity
#   CAPUE 默认 /sys/class/power_supply/battery/uevent
#   返回：解绑层数（0 = 本来就没绑定）
# ------------------------------------------------------------
uv_unbind_capacity() {
    _CAP="${1:-/sys/class/power_supply/battery/capacity}"
    _CAPUE="${2:-/sys/class/power_supply/battery/uevent}"
    _un=0
    # 先解 PID 1 全局命名空间（越狱模式下 service.sh 在这里绑的）
    if command -v nsenter >/dev/null 2>&1; then
        _un1=0
        while [ "$_un1" -lt 8 ]; do
            nsenter -t 1 -m -- umount "$_CAP" 2>/dev/null || break
            _un1=$((_un1+1))
        done
        _un=$((_un+_un1))
    fi
    # 再解当前命名空间（标准启动模式下在这里绑的）
    _un2=0
    while [ "$_un2" -lt 8 ]; do
        umount "$_CAP" 2>/dev/null || break
        _un2=$((_un2+1))
    done
    _un=$((_un+_un2))
    [ "$_un" -gt 0 ] && echo change > "$_CAPUE" 2>/dev/null
    return $_un
}

# Function libraries only; sourcing does not change device state.
if [ -n "${MODDIR:-}" ]; then
    [ -f "$MODDIR/policy.sh" ] && . "$MODDIR/policy.sh"
    [ -f "$MODDIR/restore.sh" ] && . "$MODDIR/restore.sh"
fi
