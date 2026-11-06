#!/usr/bin/env bash
# ============================================================
# uv2800 构建：从 内核源码/ 编译 .ko，同步进 模块源目录/，再打包发布 zip
#
#   ./build.sh            编译 + 打包 + 打印 md5
#   ./build.sh --no-zip   只编译，不打包
#
# 前置：
#   1) 先运行仓库根目录的 ./fetch-kernel.sh 拉取上游内核树
#   2) 首次构建前需在 编译用内核树/android_kernel_oneplus_sm8750 内完成
#      olddefconfig + modules_prepare（步骤见《THIRD-PARTY-NOTICES.md》§1.4）
#
# 产物：仓库根目录  一加13解容-v<module.prop 的 version>.zip
#
# ★ 单一真源：内核源码/uv2800.c（只改这一份）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KT="$ROOT/编译用内核树/android_kernel_oneplus_sm8750"
SRC_DIR="$ROOT/内核源码"
MOD="$ROOT/模块源目录"
SRC="$SRC_DIR/uv2800.c"

[ -d "$KT" ] || { echo "✗ 找不到内核源码树: $KT"; echo "  请先运行: $ROOT/fetch-kernel.sh"; exit 2; }
[ -f "$SRC" ] || { echo "✗ 找不到内核源码: $SRC"; exit 2; }

VER="$(grep '^version=' "$MOD/module.prop" | cut -d= -f2)"
VCODE="$(grep '^versionCode=' "$MOD/module.prop" | cut -d= -f2)"
echo "== 构建 v$VER (versionCode=$VCODE) =="
echo "   源码:   内核源码/uv2800.c ($(stat -c%s "$SRC") B)"
echo "   内核树: $KT"

export PATH=/usr/lib/llvm-18/bin:$PATH
make -C "$KT" ARCH=arm64 LLVM=1 M="$SRC_DIR" modules 2>&1 | tail -4

llvm-strip --strip-debug "$SRC_DIR/uv2800.ko"
cp -f "$SRC_DIR/uv2800.ko" "$MOD/uv2800.ko"
echo "   .ko: $(stat -c%s "$MOD/uv2800.ko") B"

# 自检
VM="$(modinfo "$MOD/uv2800.ko" | awk '/^vermagic/{print $2}')"
TM="$(readelf -S -W "$MOD/uv2800.ko" | awk '$2==".gnu.linkonce.this_module"{print $6}')"
echo "   vermagic=$VM  this_module=$TM"
[ "$TM" = "000600" ] || echo "   ⚠️ this_module 不是 0x600，可能 insmod 失败"

if [ "${1:-}" = "--no-zip" ]; then echo "== 仅编译，跳过打包 =="; exit 0; fi

OUT="$ROOT/一加13解容-v${VER}.zip"
rm -f "$OUT"
( cd "$MOD" && zip -q -r "$OUT" . -x "*.prev" )
echo ""
echo "== 产物 =="
echo "   $OUT  ($(stat -c%s "$OUT") B)"
md5sum "$OUT" "$MOD/uv2800.ko"
