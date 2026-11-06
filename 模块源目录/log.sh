#!/system/bin/sh
# 公共日志与设备树工具库
# 提供三路日志输出（stdout / kmsg / 持久化日志文件）、设备指针触发捕获、
# 设备树原厂终止电压查表计算（uv_dt_orig）及 capacity 挂载解绑函数。

UV_BK=/data/adb/uv2800_backup
UV_LOG="$UV_BK/uv2800.log"

uv_log() {
    _m="uv2800: $*"
    echo "$_m"
    echo "$_m" > /dev/kmsg 2>/dev/null
    mkdir -p "$UV_BK" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S')] $_m" >> "$UV_LOG" 2>/dev/null
}

# 打印分段标记，并在日志超过 3000 行时截断保留后 1500 行
uv_log_sep() {
    _n=$(wc -l < "$UV_LOG" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    if [ "$_n" -gt 3000 ]; then
        tail -1500 "$UV_LOG" > "$UV_LOG.tmp" 2>/dev/null && mv "$UV_LOG.tmp" "$UV_LOG" 2>/dev/null
    fi
    uv_log "---------- $1 ----------"
}

# 记录内核模块加载后自报的 profile 信息到持久化日志
uv_log_kver() {
    if ! command -v dmesg >/dev/null 2>&1; then
        uv_log "内核自报: (无 dmesg，跳过)"
        return 0
    fi
    _kv="$(dmesg 2>/dev/null | grep 'uv2800: v12 ready' | tail -1)"
    if [ -n "$_kv" ]; then
        uv_log "内核自报: ${_kv#*uv2800: }"
    else
        uv_log "内核自报: (未捕获到 'v12 ready'，insmod 可能失败)"
    fi
}

# 通过向 deep_dischg_counts 写入当前原值，触发内核 kp_ddrc 入口捕获 uv_dev
UV_DDRC=/sys/devices/virtual/oplus_chg/common/deep_dischg_counts
uv_capture_dev() {
    [ -w "$UV_DDRC" ] || return 1
    _cv=$(cat "$UV_DDRC" 2>/dev/null | tr -d "[:space:]")
    case "$_cv" in ''|*[!0-9]*) return 1 ;; esac
    echo "$_cv" > "$UV_DDRC" 2>/dev/null
    return 0
}

# 检查 $BK/adsp_state 中记录的上次成功写入值是否与目标值一致
adsp_known() {
    _k=$(cat "${BK:-$UV_BK}/adsp_state" 2>/dev/null | tr -d "[:space:]")
    case "$_k" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_k" = "$1" ] && return 0
    return 1
}

# 从设备树（ddrc_strategy）按厂商算法计算原厂终止电压：
#   1. ratio = 10 * deep_dischg_counts / cc（仅当 0 < cc < 5000 时做除法）
#   2. 将 ratio 与 oplus,ratio_range（5 项）比较，确定比例分档（min ~ high）
#   3. 将电池温度与 oplus,temp_range（3 项）比较，确定温度分档（cold ~ warm）
#   4. 读取对应分档表（每行 4 个大端 u32：f0, vbat0, vbat1, idx），
#      选取满足 max(0, f0 - count_cali) <= cc 的最后一行，返回第 3 列 vbat1（终止电压）。
#   任一结构或范围自检未通过时直接返回非零错误码，不输出猜测值。
uv_dt_orig() {
    _dtb=${UV_T_DTB:-/sys/firmware/devicetree/base/soc/oplus,mms_gauge}

    _o_fail() {
        _om="[uv_dt_orig] FAIL $1 (batt=${_batt:-?} cnt=${_o_cnt:-?} cc=${_o_cc:-?} cali=${_o_cali:-?} temp=${_o_temp:-?})"
        echo "$_om" >&2
        _ol="${UV_LOG:-/data/adb/uv2800_backup/uv2800.log}"
        mkdir -p "${_ol%/*}" 2>/dev/null
        echo "[$(date '+%m-%d %H:%M:%S')] uv2800: $_om" >> "$_ol" 2>/dev/null
        return 0
    }

    # 优先按 battery_type 定位电池子节点；回退扫描时若与已知 battery_type 不一致则拒绝
    _o_bt=${UV_T_BATT:-$(cat /sys/class/oplus_chg/battery/battery_type 2>/dev/null)}
    _batt=""
    if [ -n "$_o_bt" ] && [ -d "$_dtb/$_o_bt/ddrc_strategy" ]; then
        _batt=$_o_bt
    else
        for _d in "$_dtb"/*/; do
            [ -d "${_d}ddrc_strategy" ] || continue
            _batt=$(basename "$_d"); break
        done
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
    if [ -e /sys/devices/virtual/oplus_chg/common/deep_dischg_count_cali ]; then
        case "$_o_cali" in
            ''|*[!0-9]*)
                _o_fail "count_cali 读值非法: '$_o_cali'（节点存在但不可解析）"
                return 1 ;;
        esac
    else
        _o_cali=0
    fi

    # 限制输入位数与上界，防止 64 位整数运算溢出
    case "$_o_cnt"  in ??????????*) _o_fail "counts 超上界(≥10位): $_o_cnt";      return 1 ;; esac
    case "$_o_cc"   in ??????????*) _o_fail "cc 超上界(≥10位): $_o_cc";          return 1 ;; esac
    case "$_o_cali" in ??????????*) _o_fail "count_cali 超上界(≥10位): $_o_cali"; return 1 ;; esac
    if [ "$_o_cnt"  -gt 1000000 ]; then _o_fail "counts 超上界: $_o_cnt (max 1e6)";  return 1; fi
    if [ "$_o_cc"   -gt 1000000 ]; then _o_fail "cc 超上界: $_o_cc (max 1e6)";      return 1; fi
    if [ "$_o_cali" -gt 10000   ]; then _o_fail "count_cali 超上界: $_o_cali (max 1e4)"; return 1; fi

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

    if [ "$_o_cnt" -eq 0 ] && [ "$_o_cc" -eq 0 ]; then
        _o_fail "counts 与 cc 同时为 0，无法定档"
        return 1
    fi

    _o_ratio=$(( 10 * _o_cnt ))
    if [ "$_o_cc" -gt 0 ] && [ "$_o_cc" -lt 5000 ]; then
        _o_ratio=$(( 10 * _o_cnt / _o_cc ))
    fi

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
            if (v0 < 2000 || v0 > 5000 || v1 < 2000 || v1 > 5000) { print "ERR volt_range"; exit }
            if (i == 0) { if (f0 != 0) { print "ERR f0_base"; exit } }
            else if (f0 < prev) { print "ERR f0_order"; exit }
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
    if [ "$_o_val" -lt 2900 ] || [ "$_o_val" -gt 3500 ]; then
        _o_fail "结果越界: $_o_val（期望 2900~3500）"
        return 1
    fi
    if [ "$UV_DT_DEBUG" = 1 ]; then
        echo "[uv_dt_orig] batt=$_batt cnt=$_o_cnt cc=$_o_cc cali=$_o_cali temp=${_o_temp:-NA} ratio=$_o_ratio region=$_o_region($_o_rname) index_t=$_o_it($_o_tname) -> $_o_val mV" >&2
    fi
    echo "$_o_val"
}

# 解除 chip_soc 到 capacity 的所有 bind-mount（覆盖 PID 1 全局命名空间与当前命名空间）
uv_unbind_capacity() {
    _CAP="${1:-/sys/class/power_supply/battery/capacity}"
    _CAPUE="${2:-/sys/class/power_supply/battery/uevent}"
    _un=0
    if command -v nsenter >/dev/null 2>&1; then
        _un1=0
        while [ "$_un1" -lt 8 ]; do
            nsenter -t 1 -m -- umount "$_CAP" 2>/dev/null || break
            _un1=$((_un1+1))
        done
        _un=$((_un+_un1))
    fi
    _un2=0
    while [ "$_un2" -lt 8 ]; do
        umount "$_CAP" 2>/dev/null || break
        _un2=$((_un2+1))
    done
    _un=$((_un+_un2))
    [ "$_un" -gt 0 ] && echo change > "$_CAPUE" 2>/dev/null
    return $_un
}
