#!/system/bin/sh
# ============================================================
# uv2800 - 操作按钮：把「原值」写回电量计 ADSP
#
# 【为什么需要这个按钮】
#   社区主流方案是修改 dtbo。刷回原版 dtbo 也【不能】恢复电量计里
#   已经被写入的终止电压，只能等它按约 20mV/次充放电慢慢恢复。
#   本按钮提供一个手动恢复手段。
#
# 【原值是怎么算出来的】
#   原值是【计算值】：
#       目标电压 = term_coeff 表中「最后一条 count <= 当前深度放电次数」的电压
#   已验证：COS17 真机 count=1734 → 3250，与驱动日志完全一致。
#   本脚本直接读实时 DT + sysfs 计算，不依赖任何硬编码。
#
# 【试运行】
#   UV2800_DRYRUN=1 sh action.sh   # 只算不写，用于验证计算路径
# ============================================================

DTBASE=/sys/firmware/devicetree/base/soc/oplus,mms_gauge
CNTFILE=/sys/devices/virtual/oplus_chg/common/deep_dischg_counts
PARAM=/sys/module/uv2800/parameters/restore
VBAT=/sys/class/oplus_chg/battery/vbat_uv
VOLT_NOW=/sys/class/power_supply/battery/voltage_now
BK=/data/adb/uv2800_backup

echo "=========================================="
echo "  uv2800  恢复原值（写回电量计 ADSP）"
[ "$UV2800_DRYRUN" = "1" ] && echo "  【试运行模式：只算不写】"
echo "=========================================="
echo ""

if [ ! -e "$PARAM" ]; then
    echo "✗ 找不到 $PARAM"
    echo "  说明模块没有加载。请检查："
    echo "  - /data/adb/modules/uv2800/disable 是否存在"
    echo "  - 或重启手机后再试"
    exit 1
fi

# --- 0) 低电压警告（v10 新增）--------------------------------------
# 实测依据（文档 §23.4.4）：若在电量计空电点附近（vbat < 回写目标）执行回写，
# vbat < term 会让电量计进入钳位态（DOD=100% 不自愈），需要充满一次才恢复。
# 注意：本机 voltage_now 是【单芯】电压（µV），不是双芯之和。
VN=$(cat "$VOLT_NOW" 2>/dev/null)
case "$VN" in ''|*[!0-9]*) VN=0 ;; esac
VN=$((VN / 1000))
if [ "$VN" -gt 0 ]; then
    echo "- 当前电池电压: ${VN} mV"
    if [ "$VN" -lt 3300 ]; then
        echo ""
        echo "  ⚠️⚠️ 电池电压偏低（< 3300mV）⚠️⚠️"
        echo "  建议先充电到 3250mV 以上再执行回写，"
        echo "  否则电量计可能进入钳位态（SOC 卡 0%，需充满一次才恢复）。"
        echo ""
    fi
fi

# --- 1) 找电池型号子节点 -----------------------------------
BATT=""
for d in "$DTBASE"/*/; do
    [ -f "${d}deep_spec,term_coeff" ] || continue
    BATT=$(basename "$d")
    break
done

if [ -z "$BATT" ]; then
    echo "✗ 在 $DTBASE 下找不到带 deep_spec,term_coeff 的电池节点"
    exit 1
fi

TABLE="$DTBASE/$BATT/deep_spec,term_coeff"
echo "- 电池节点   : $BATT"

# --- 2) 读当前深度放电次数 ---------------------------------
if [ ! -e "$CNTFILE" ]; then
    echo "✗ 找不到 $CNTFILE"
    exit 1
fi
CNT=$(cat "$CNTFILE" 2>/dev/null)
echo "- 放电次数   : $CNT"

# --- 3) 计算原值：① 首次写入前的备份  ② DT 表实时计算（兜底）---------
# 【为什么优先用备份】service.sh 在【首次写入前】把电量计当时的真实值存进
# adsp_orig.txt，那个值就是驱动自己算出来的原值（与本机驱动日志
# "DEEP_COUNT_VOTER, volt = 3250" 完全一致）。它与 ColorOS 版本无关，
# 比查 DT 表可靠得多（C16 的表档位从 800 起，count<800 时查表必然失败）。
TARGET=""
ORIG="$BK/adsp_orig.txt"
if [ -f "$ORIG" ]; then
    T=$(cat "$ORIG" 2>/dev/null | tr -d "[:space:]")
    case "$T" in ''|*[!0-9]*) T="" ;; esac
    if [ -n "$T" ] && [ "$T" -ge 2000 ] && [ "$T" -le 5000 ]; then
        TARGET="$T"
        echo "- 原值来源   : 首次写入前的备份 adsp_orig.txt"
    fi
fi

if [ -z "$TARGET" ]; then
    echo "- 原值来源   : DT 表实时计算（adsp_orig.txt 缺失或无效）"
    TARGET=$(od -An -tx1 -v "$TABLE" 2>/dev/null | tr -s ' \n' '\n' | grep -v '^$' | awk -v cnt="$CNT" '
function hex2dec(h,   i, c, d, v) {
    v = 0
    for (i = 1; i <= length(h); i++) {
        c = tolower(substr(h, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}
{ b[n++] = $1 }
END {
    tgt = -1
    for (i = 0; i + 11 < n; i += 12) {
        v = hex2dec(b[i] b[i+1] b[i+2] b[i+3])
        c = hex2dec(b[i+4] b[i+5] b[i+6] b[i+7])
        if (v < 0 || c < 0) continue
        if (i == 0) tgt = v
        if (c <= cnt) tgt = v
    }
    print tgt
}')
fi

case "$TARGET" in ''|*[!0-9]*) TARGET=-1 ;; esac
if [ "$TARGET" -lt 2000 ] || [ "$TARGET" -gt 5000 ]; then
    echo "✗ 计算失败（得到 '$TARGET'）"
    echo "  请把以下信息反馈给作者："
    echo "    deep_dischg_counts = $CNT"
    echo "    使用的表 = $TABLE"
    echo "    adsp_orig.txt = $([ -f "$ORIG" ] && cat "$ORIG" || echo '不存在')"
    exit 1
fi
echo "- 算出的原值 : ${TARGET} mV"
echo ""

if [ "$UV2800_DRYRUN" = "1" ]; then
    echo "【试运行】目标值 ${TARGET} mV 计算完成，未执行任何写入。"
    exit 0
fi

# --- 4) 写回 -----------------------------------------------
echo "- 当前 vbat_uv: $(cat $VBAT 2>/dev/null) mV"

# 越狱(late-load)模式下模块刚加载时拿不到驱动设备指针，写回会失败。
# 实测：插拔一次充电器会让驱动重新投票并调用 getter，模块随即捕获指针。
PREAD=/sys/module/uv2800/parameters/adsp_read
if [ -w "$PREAD" ]; then
    echo 1 > "$PREAD" 2>/dev/null
    READY=$(cat "$PREAD" 2>/dev/null)
    if [ -z "$READY" ] || [ "$READY" -le 2000 ] 2>/dev/null; then
        echo ""
        echo "- ⚠️ 模块尚未就绪（越狱模式下驱动只在开机调用 getter）"
        echo "-    请【插拔一次充电器】，最多等待 60 秒 ..."
        i=0
        while [ "$i" -lt 30 ]; do
            sleep 2
            echo 1 > "$PREAD" 2>/dev/null
            READY=$(cat "$PREAD" 2>/dev/null)
            if [ -n "$READY" ] && [ "$READY" -gt 2000 ] 2>/dev/null; then
                echo "-    ✅ 已就绪（电量计当前值 $READY mV）"
                break
            fi
            i=$((i+1))
        done
        [ "$i" -ge 30 ] && echo "-    ❌ 等待超时，写回可能失败；可重启手机后重试"
    fi
fi

echo "- 写回中 ..."
echo "$TARGET" > "$PARAM"
echo "- 写入返回   : $?"

sleep 2

echo ""
echo "- 内核日志："
dmesg 2>/dev/null | grep "uv2800:" | grep -v "Modules linked" | tail -4

# --- 5) 同时恢复「禁止超级省电」设备策略 ---------------------
XML=/data/system/oplus_devicepolicy_data_customize.xml
KEY=oplus_diable_super_power_saving_mode

echo ""
echo "- 恢复设备策略（超级省电）..."
su 1000 -c "service call oplusdevicepolicy 1 s16 $KEY s16 false i32 1" >/dev/null 2>&1
if [ -f "$BK/orig_state" ]; then
    if [ "$(cat "$BK/orig_state" 2>/dev/null)" = "existed" ] && [ -f "$BK/devicepolicy_orig.xml" ]; then
        cp -f "$BK/devicepolicy_orig.xml" "$XML"
        chown system:system "$XML" 2>/dev/null
        chmod 600 "$XML" 2>/dev/null
    else
        rm -f "$XML"
    fi
fi
# 打上 skip 标记：以后开机不再重新应用设备策略
mkdir -p "$BK" && touch "$BK/skip"
rm -f "$BK/adsp_target" "$BK/no_adsp_write"
echo "- 已恢复（超级省电功能将恢复可用）"

# --- 6) 恢复官方平滑电量显示 ---
CAP=/sys/class/power_supply/battery/capacity
# /proc/mounts 里记录的是解析后的真实路径，所以直接尝试 umount
if umount "$CAP" 2>/dev/null; then
    echo change > /sys/class/power_supply/battery/uevent 2>/dev/null
    echo "- 已恢复官方平滑电量显示"
else
    echo "- 电量显示本来就是官方平滑值，无需恢复"
fi

echo ""
echo "=========================================="
echo "  回写完成！"
echo ""
echo "  已同时完成："
echo "   · 电量计终止电压回写原值"
echo "   · 超级省电设备策略恢复"
echo "   · 官方平滑电量显示恢复"
echo ""
echo "  接下来请："
echo "   1. 关闭（或卸载）本模块"
echo "   2. 重启手机"
echo "   3. 验证：cat $VBAT"
echo "      应显示 ${TARGET}"
echo ""
echo "  若以后重新启用本模块，请先执行："
echo "   rm /data/adb/uv2800_backup/skip"
echo "  （否则「禁止超级省电」策略不会重新应用）"
echo "=========================================="
