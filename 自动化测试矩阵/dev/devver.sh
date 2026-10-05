#!/system/bin/sh
# ============================================================
# uv2800 测试：设备/内核/驱动版本戳
#   P2-14 修复（2026-10-04）：测试报告此前只记 device+zip md5，
#   结果无法自证跑在哪套 ColorOS/内核上。
#   本脚本输出 key=value，由 run.sh 采集并写入 report.{json,md}
# ============================================================
gp() { getprop "$1" 2>/dev/null | tr -d '[:space:]'; }
echo "dev_model=$(gp ro.product.model)"
echo "dev_device=$(gp ro.product.device)"
echo "dev_rom=$(gp ro.build.display.id)"
echo "dev_oplusrom=$(gp ro.build.version.oplusrom)"
echo "dev_android=$(gp ro.build.version.release)"
k="$(uname -r 2>/dev/null | tr -d '[:space:]')"
echo "dev_kernel=$k"
echo "dev_build_date=$(gp ro.build.date)"
mod="$(md5sum /data/adb/modules/uv2800/uv2800.ko 2>/dev/null | cut -d' ' -f1)"
echo "dev_modko=${mod:-?}"

# ---- 跨 ROM / 跨内核兼容性矩阵用（2026-10-04 增）----
echo "dev_slot=$(gp ro.boot.slot_suffix)"
echo "dev_vbstate=$(gp ro.boot.verifiedbootstate)"
echo "dev_buildtype=$(gp ro.build.type)"
# 被 hook 的厂商驱动：换 ROM/内核后它的 md5 会变，hook 偏移是否仍匹配先看它
_chg="$(md5sum /vendor/lib/modules/oplus_chg_v2.ko 2>/dev/null | cut -d' ' -f1)"
echo "dev_chgko=${_chg:-?}"
# 内核模块自报的 profile（uv2800.c:622 pr_info）—— 版本自适应选中了哪一支
# 只能从 dmesg 抓；本机环形缓冲约 10 分钟被冲掉，抓不到记 ?
# （dmesg 很大，必须走管道，不能存进变量：会 Argument list too long）
_psrc=dmesg
_p="$(dmesg 2>/dev/null | grep -o 'profile=\[[^]]*\]' | tail -1)"
if [ -z "$_p" ]; then
    # v11.1：模块脚本已在 insmod 后把该行落盘 → dmesg 被冲掉也能拿到
    _psrc=log
    _p="$(grep -o 'profile=\[[^]]*\]' /data/adb/uv2800_backup/uv2800.log 2>/dev/null | tail -1)"
fi
[ -n "$_p" ] || _psrc=?
echo "dev_profile=${_p:-?}"
echo "dev_profile_src=${_psrc}"
_h="$(dmesg 2>/dev/null | grep -o 'v11 ready, [0-9]* 个 hook' | tail -1)"
[ -z "$_h" ] && _h="$(grep -o 'v11 ready, [0-9]* 个 hook' /data/adb/uv2800_backup/uv2800.log 2>/dev/null | tail -1)"
echo "dev_hooks=${_h:-?}"
echo "dev_uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
# 越狱 profile 指纹（GLK1：release 字符串从第 16 字节起）—— 兼容矩阵要记「这次越狱用的哪份」
if [ -f /data/local/tmp/profile.bin ]; then
    echo "dev_jbprofile_md5=$(md5sum /data/local/tmp/profile.bin 2>/dev/null | cut -d' ' -f1)"
    # release 长度存在 GLK1 头部偏移 12（u16 LE），按长度精确取，避免带出后面的 key 名
    _jl="$(od -An -tu2 -j12 -N2 /data/local/tmp/profile.bin 2>/dev/null | tr -d ' ')"
    _jr=""
    case "${_jl:-}" in ''|*[!0-9]*) ;; *) _jr="$(dd if=/data/local/tmp/profile.bin bs=1 skip=16 count="$_jl" 2>/dev/null | tr -d '\000')" ;; esac
    echo "dev_jbprofile_rel=${_jr:-}"
fi
