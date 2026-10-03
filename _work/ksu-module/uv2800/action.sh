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

MODDIR=${0%/*}
# v10.7：日志函数（stdout + dmesg + 落盘到备份目录），见 log.sh
[ -f "$MODDIR/log.sh" ] && . "$MODDIR/log.sh"
command -v uv_log >/dev/null 2>&1 || uv_log() { echo "uv2800: $*"; }
uv_log_sep "action.sh 恢复原值 开始"

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
    if [ -n "$T" ] && [ "$T" -le 2900 ] 2>/dev/null; then
        # v10.8：备份值 <=2900 必为本模块写过的值（真原值最低档 3000，见 DT term_coeff），属历史污染，不可信。
        # 隔离该文件并改用 DT 查表兜底（v10.7 实机教训：曾按污染的 2800 回写）。
        echo "- ⚠️ adsp_orig.txt=$T mV 疑似历史污染值（原值应 >2900），已隔离，改用 DT 查表"
        uv_log "adsp_orig.txt=$T 疑似污染，已隔离为 adsp_orig.bad"
        mv -f "$ORIG" "$BK/adsp_orig.bad" 2>/dev/null
        T=""
    fi
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

# 【仅越狱模式】模块加载太晚错过开机那次 getter 调用，uv_dev 为空会写不进。
# 标准模式开机 vote 时已捕获 uv_dev，无需此检测。插拔充电器会触发驱动重新
# vote 并调用 getter，模块随即捕获指针。超时【中止】而非假成功（v10.5 修复）。
if [ "$KSU_LATE_LOAD" = "1" ]; then
    PREAD=/sys/module/uv2800/parameters/adsp_read
    echo 1 > "$PREAD" 2>/dev/null
    READY=$(cat "$PREAD" 2>/dev/null)
    if [ -z "$READY" ] || [ "$READY" -le 2000 ] 2>/dev/null; then
        echo ""
        echo "- ⚠️ 越狱模式：模块尚未捕获驱动指针（开机 vote 已错过）"
        echo "-    请【插拔一次充电器】，最多等待 60 秒 ..."
        NEEDED_PLUG=1        # v10.7：记录本次已提示插拔
        i=0; ok=0
        while [ "$i" -lt 30 ]; do
            sleep 2
            echo 1 > "$PREAD" 2>/dev/null
            READY=$(cat "$PREAD" 2>/dev/null)
            if [ -n "$READY" ] && [ "$READY" -gt 2000 ] 2>/dev/null; then
                echo "-    ✅ 已就绪（电量计当前值 $READY mV）"; ok=1; break
            fi
            i=$((i+1))
        done
        if [ "$ok" != "1" ]; then
            echo ""
            echo "  ✗✗ 仍未就绪，已【中止】回写（电量计未被改动）✗✗"
            echo "  请先插拔一次充电器，再重新点「执行」。"
            exit 1
        fi
    fi
fi
# --- 3.5) ★ 先打 skip 标记（v10.7 关键修复）--------------------------
# 【为什么必须在回写之前】service.sh 的 60 秒探测循环、以及后台 adsp_retry，
# 会不断把 ADSP 写回解耦目标（2600）。若 skip 在回写【之后】才创建，
# 这两个循环会在等待期间把刚恢复的原值又覆盖掉（实测：回写后 1 秒被撤销）。
mkdir -p "$BK" && touch "$BK/skip"
echo "- 已打上 skip 标记（service.sh 的解耦循环会立即停手）"
echo ""
echo "- 写回中 ..."
echo "$TARGET" > "$PARAM"
echo "- 写入返回   : $?"

sleep 2

echo ""
echo "- 内核日志："
dmesg 2>/dev/null | grep "uv2800:" | grep -v "Modules linked" | tail -4

# --- 4.5) ★ 刷新驱动侧的 vbat_uv 缓存（v10.7 新增）------------------
# 【为什么需要】vbat_uv 不是 ADSP 的直读值，而是驱动内部的【缓存】：
#   · 开机初始化时由驱动按 ADSP 算出来
#   · 之后只在【vote】（插拔充电器 / 充电状态变化）时重新计算
# 而模块的 getter hook 在 uv_bypass=0 时会把驱动刷新的值强制写成 2800；
# 点「执行」后 uv_bypass=1（hook 已放行），此时插拔即可正常刷新为原值。
# 所以回写 ADSP 后，vbat_uv 仍显示旧的 2800 —— 必须触发一次 vote 才会更新。
# 【越狱模式特别注意】Manager 的重启在越狱模式下是【软重启】（ksud soft-reboot），
# 内核不重启 → 驱动不重新初始化 → 缓存【不会】刷新。只有插拔充电器才行。
CURV=$(cat "$VBAT" 2>/dev/null | tr -d "[:space:]")
if [ "$CURV" != "$TARGET" ]; then
    if [ "$NEEDED_PLUG" = "1" ]; then
        # 刚才那次插拔是为捕获指针（发生在回写【之前】，此时 uv_bypass 还是 0），
        # 驱动缓存被 getter hook 写成了 2800。回写后 uv_bypass=1（hook 已放行），
        # 必须【再插拔一次】才会刷新成原值 —— 这不是重复提示，是必要的第二次。
        echo ""
        echo "- 刚才那次插拔发生在回写【之前】，驱动缓存被 hook 写成了 2800"
        echo "-    请【再插拔一次充电器】（这次 hook 已放行，才会刷新为 $TARGET mV）"
    else
        echo ""
        echo "- 驱动 vbat_uv 缓存仍是 $CURV mV，需要一次 vote 才会更新为 $TARGET mV"
        echo "-    请【插拔一次充电器】，最多等待 60 秒 ..."
    fi
    j=0; okv=0
    while [ "$j" -lt 30 ]; do
        sleep 2
        CURV=$(cat "$VBAT" 2>/dev/null | tr -d "[:space:]")
        if [ "$CURV" = "$TARGET" ]; then
            echo "-    ✅ vbat_uv 已刷新为 $CURV mV"; okv=1; break
        fi
        j=$((j+1))
    done
    if [ "$okv" != "1" ]; then
        echo "-    ⚠️ 未检测到插拔（vbat_uv 仍为 $CURV mV）"
        echo "-       不影响 ADSP 回写结果；之后任意时刻插拔一次充电器即可刷新。"
    fi
else
    okv=skip        # v10.8：回写后缓存已是目标值，无需插拔刷新（结尾提示据此区分）
fi

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
# ⚠️ 越狱模式下 service.sh 用 `nsenter -t 1 -m` 在 PID 1 全局命名空间绑定，
#    这里也必须 nsenter 进去才解绑得到；再兜底本命名空间（标准启动模式）。
#    注意：/proc/mounts 只显示最顶层，不能靠它判断是否绑定。
_un=0
if command -v nsenter >/dev/null 2>&1; then
    while [ "$_un" -lt 8 ]; do
        nsenter -t 1 -m -- umount "$CAP" 2>/dev/null || break
        _un=$((_un+1))
    done
fi
while [ "$_un" -lt 8 ]; do
    umount "$CAP" 2>/dev/null || break
    _un=$((_un+1))
done
if [ "$_un" -gt 0 ]; then
    echo change > /sys/class/power_supply/battery/uevent 2>/dev/null
    echo "- 已恢复官方平滑电量显示（解绑 $_un 层）"
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
# v10.8：区分三种情况，避免矛盾提示
#   okv=1      ：等待期间已检测到刷新
#   okv=skip   ：回写后 vbat_uv 已等于目标值，无需刷新（本次未进入等待）
#   其他       ：需要用户插拔一次充电器
if [ "$okv" = "1" ]; then
    echo "   2. vbat_uv 已刷新为 ${TARGET} mV，直接卸载/重启即可"
elif [ "$okv" = "skip" ]; then
    echo "   2. vbat_uv 已是 ${TARGET} mV，无需刷新，直接卸载/重启即可"
else
    echo "   2. 【插拔一次充电器】刷新驱动 vbat_uv 缓存"
    echo "      （越狱模式下 Manager 的「重启」是软重启，内核不重启，缓存不会刷新）"
fi
echo "   3. 验证：cat $VBAT   应显示 ${TARGET}"
echo "      或看驱动内部 fcc：dmesg | grep bs_update_data | tail -1"
echo ""
uv_log "恢复完成：原值 ${TARGET} mV，vbat_uv 刷新=${okv:-0}（1=已刷新 skip=本已相等）"
echo "  若以后重新启用本模块，请先执行："
echo "   rm /data/adb/uv2800_backup/skip"
echo "  （否则「禁止超级省电」策略与真实电量显示都不会重新应用）"
echo "=========================================="
