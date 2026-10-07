#!/usr/bin/env bash
# ============================================================
# uv2800 构建：从 内核源码/ 编译 .ko，同步进 模块源目录/，再打包发布 zip
#
#   ./build.sh            编译 + 打包 + 打印 SHA256
#   ./build.sh --no-zip   只编译，不打包
#
# 前置：
#   1) 先运行仓库根目录的 ./fetch-kernel.sh 拉取上游内核树
#   2) 运行 bash 自动化测试矩阵/prepare-kernel.sh 配置并准备内核树
#
# 产物：仓库根目录  一加13解容-v<module.prop 的 version>.zip
#
# ★ 单一真源：内核源码/uv2800.c（只改这一份）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KT="${KERNEL_DIR:-$ROOT/编译用内核树}/android_kernel_oneplus_sm8750"
SRC_DIR="$ROOT/内核源码"
MOD="$ROOT/模块源目录"
SRC="$SRC_DIR/uv2800.c"
METADATA="$SCRIPT_DIR/host/build_metadata.py"
case "${1:-}" in ''|--no-zip) ;; *) echo "未知参数: $1" >&2; exit 2 ;; esac

[ -d "$KT" ] || { echo "✗ 找不到内核源码树: $KT"; echo "  请先运行: $ROOT/fetch-kernel.sh"; exit 2; }
[ -f "$SRC" ] || { echo "✗ 找不到内核源码: $SRC"; exit 2; }

VER="$(grep '^version=' "$MOD/module.prop" | cut -d= -f2)"
VCODE="$(grep '^versionCode=' "$MOD/module.prop" | cut -d= -f2)"
echo "== 构建 v$VER (versionCode=$VCODE) =="
echo "   源码:   内核源码/uv2800.c ($(stat -c%s "$SRC") B)"
echo "   内核树: $KT"

export PATH=/usr/lib/llvm-18/bin:$PATH
for tool in make clang llvm-strip python3; do command -v "$tool" >/dev/null || { echo "缺少工具: $tool" >&2; exit 2; }; done
COMPILER="$(clang --version | head -1)"
[[ "$COMPILER" == *"clang version 18."* ]] || { echo "✗ 需要 LLVM 18，当前：$COMPILER" >&2; exit 2; }
PIN="$(python3 -c 'import runpy,sys; print(runpy.run_path(sys.argv[1])["KERNEL_COMMIT"])' "$METADATA")"
[ "$(git -C "$KT" rev-parse HEAD)" = "$PIN" ] || { echo "✗ 内核树不是固定提交 $PIN" >&2; exit 1; }

# 从复制的源文件全新构建；失败或 ABI 不匹配时保留原发布 .ko。
STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT
cp "$SRC" "$SRC_DIR/Makefile" "$STAGE/"
make -C "$KT" ARCH=arm64 LLVM=1 M="$STAGE" modules
llvm-strip --strip-debug "$STAGE/uv2800.ko"
python3 "$METADATA" create --root "$ROOT" --module "$STAGE/uv2800.ko" \
  --source-dir "$STAGE" --kernel "$KT" --compiler "$COMPILER" \
  --manifest "$STAGE/uv2800.build.json"
python3 "$METADATA" verify --root "$ROOT" --module "$STAGE/uv2800.ko" --manifest "$STAGE/uv2800.build.json"
cp "$STAGE/uv2800.ko" "$MOD/uv2800.ko"
cp "$STAGE/uv2800.build.json" "$MOD/uv2800.build.json"
echo "   .ko: $(stat -c%s "$MOD/uv2800.ko") B（ABI/源码清单校验通过）"

if [ "${1:-}" = "--no-zip" ]; then echo "== 仅编译，跳过打包 =="; exit 0; fi

OUT="$ROOT/一加13解容-v${VER}.zip"
python3 "$METADATA" verify --root "$ROOT"
( cd "$MOD" && zip -q -r "$STAGE/module.zip" . -x "*.prev" "*.tmp" )
mv -f "$STAGE/module.zip" "$OUT"
echo ""
echo "== 产物 =="
echo "   $OUT  ($(stat -c%s "$OUT") B)"
sha256sum "$OUT" "$MOD/uv2800.ko"
