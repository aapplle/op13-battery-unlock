#!/usr/bin/env bash
# ============================================================
# uv2800 构建：从【当前源码】编译 .ko 并打包 zip（测试流程的第一步）
#   ./build.sh            编译 + 打包 + 打印 md5
#   ./build.sh --no-zip   只编译，不打包
# 产物：<ksu-module>/一加13解容-v<module.prop 的 version>.zip
#
# ★ 单一真源（v11.0 起）：
#     真源 = 02-当前最新构建/内核源码/uv2800.c   ← 只改这一份
#     构建 = 04-编译用内核树/kmod/uv2800.c       ← 由本脚本自动同步，勿手改
#   历史教训：这两份曾各自被编辑而互不感知（2026-10-04 发现注释分叉），
#   根因是构建流程里【没有同步步骤】。现在改为编译前强制同步 + sha256 自检。
#   临时要绕过同步（如手工改 kmod 调试）：UV_NO_SYNC=1 ./build.sh
# ============================================================
set -euo pipefail

KB=<WORKSPACE>/04-编译用内核树
KT="$KB/android_kernel_common_oneplus_sm8750-oneplus-sm8750_b_16.0.0_oneplus_13"
MOD=<WORKSPACE>/02-当前最新构建/模块源目录
SRC=<WORKSPACE>/02-当前最新构建/内核源码/uv2800.c
KSRC="$KB/kmod/uv2800.c"

[ -d "$KT" ] || { echo "✗ 找不到内核源码树: $KT"; exit 2; }

# ---------- 编译前：把【真源】单向同步进构建沙盒 ----------
if [ "${UV_NO_SYNC:-0}" = "1" ]; then
    echo "   ⚠️ UV_NO_SYNC=1：跳过源码同步，直接用 $KSRC"
elif [ ! -f "$SRC" ]; then
    echo "   ⚠️ 找不到真源 $SRC，沿用 $KSRC"
else
    if [ ! -f "$KSRC" ] || ! cmp -s "$SRC" "$KSRC"; then
        if [ -f "$KSRC" ]; then
            _bak="$KB/kmod/_archive/uv2800.c.bak.$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$KB/kmod/_archive"
            cp -f "$KSRC" "$_bak"
            echo "   已备份被覆盖的构建源 → ${_bak#$KB/}"
        fi
        cp -f "$SRC" "$KSRC"
        echo "   ✅ 已同步 内核源码/uv2800.c → kmod/uv2800.c"
    else
        echo "   ✅ 真源与构建源一致，无需同步"
    fi
    _a="$(sha256sum "$SRC" | cut -c1-16)"
    _b="$(sha256sum "$KSRC" | cut -c1-16)"
    [ "$_a" = "$_b" ] || { echo "✗ 同步后 sha256 仍不一致（$_a vs $_b），中止"; exit 3; }
    echo "   sha256(前16): $_a"
fi

[ -f "$KSRC" ] || { echo "✗ 找不到内核源码: $KSRC"; exit 2; }

VER="$(grep '^version=' "$MOD/module.prop" | cut -d= -f2)"
VCODE="$(grep '^versionCode=' "$MOD/module.prop" | cut -d= -f2)"
echo "== 构建 v$VER (versionCode=$VCODE) =="
echo "   源码: $KB/kmod/uv2800.c  ($(stat -c%s "$KB/kmod/uv2800.c") B)"

export PATH=/usr/lib/llvm-18/bin:$PATH
cd "$KT"
make ARCH=arm64 LLVM=1 M="$KB/kmod" modules 2>&1 | tail -4

llvm-strip --strip-debug "$KB/kmod/uv2800.ko"
# 备份放到模块目录【之外】（否则会被 zip -r . 打进包里，实测踩过）
BAK=<WORKSPACE>/02-当前最新构建/_bak
mkdir -p "$BAK"
[ -f "$MOD/uv2800.ko" ] && cp -f "$MOD/uv2800.ko" "$BAK/uv2800.ko.prev" && echo "   已备份旧 .ko → _bak/uv2800.ko.prev"
cp -f "$KB/kmod/uv2800.ko" "$MOD/uv2800.ko"
echo "   .ko: $(stat -c%s "$MOD/uv2800.ko") B"

# 自检
VM="$(modinfo "$MOD/uv2800.ko" | awk '/^vermagic/{print $2}')"
TM="$(readelf -S -W "$MOD/uv2800.ko" | awk '$2==".gnu.linkonce.this_module"{print $6}')"
echo "   vermagic=$VM  this_module=$TM"
[ "$TM" = "000600" ] || echo "   ⚠️ this_module 不是 0x600，可能 insmod 失败"

# 说明（v11.0 起）：单份真源为 02-当前最新构建/内核源码/uv2800.c，每次构建前自动同步到 kmod/。
# 04-编译用内核树/uv2800_v11.c 已不再维护，历史副本存于 04-编译用内核树/_archive/。

if [ "${1:-}" = "--no-zip" ]; then echo "== 仅编译，跳过打包 =="; exit 0; fi

OUT="<WORKSPACE>/02-当前最新构建/一加13解容-v${VER}.zip"
[ -f "$OUT" ] && cp -f "$OUT" "$BAK/$(basename "$OUT").prev" && echo "   已备份旧 zip → _bak/"
rm -f "$OUT"
# 排除 *.prev（双保险：备份已移出模块目录）
( cd "$MOD" && zip -q -r "$OUT" . -x "*.prev" )
echo ""
echo "== 产物 =="
echo "   $OUT  ($(stat -c%s "$OUT") B)"
md5sum "$OUT" "$MOD/uv2800.ko"
echo ""
echo "下一步：UV_ZIP=\"$OUT\" ./run.sh T1 T2 T6"
