#!/usr/bin/env bash
# ============================================================
# fetch-kernel.sh —— 拉取编译 uv2800.ko 所需的上游内核源码树
#
# 本仓库【不分发】内核源码树（GPL-2.0，一加官方已公开发布）。
# 上游地址、固定版本、许可证与编译方法见同目录《THIRD-PARTY-NOTICES.md》§一。
#
# 用法:
#   ./fetch-kernel.sh                          # 默认落到 ./编译用内核树/android_kernel_oneplus_sm8750
#   KERNEL_DIR=/data/kernel ./fetch-kernel.sh  # 自定义落点
# ============================================================
set -euo pipefail

REPO_URL="https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750.git"
BRANCH="oneplus/sm8750_b_16.0.0_oneplus_13"
COMMIT="6028f47faddaa27700f8dd3a1d83906ea8f27170"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-${ROOT_DIR}/编译用内核树}"
TARGET="${KERNEL_DIR}/android_kernel_oneplus_sm8750"

echo "== 拉取上游内核树 =="
echo "   仓库: $REPO_URL"
echo "   分支: $BRANCH"
echo "   目标: $TARGET"

if [ -d "$TARGET/.git" ]; then
    echo "   目录已存在，定位固定提交 ..."
else
    mkdir -p "$KERNEL_DIR"
    git init "$TARGET"
    git -C "$TARGET" remote add origin "$REPO_URL"
fi

if ! git -C "$TARGET" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    git -C "$TARGET" fetch --depth 1 origin "$COMMIT" || {
        echo "✗ 固定提交获取失败，未就绪：$COMMIT" >&2
        exit 1
    }
fi
git -C "$TARGET" checkout --detach "$COMMIT"
HEAD_SHA="$(git -C "$TARGET" rev-parse HEAD)"
[ "$HEAD_SHA" = "$COMMIT" ] || { echo "✗ HEAD 与固定提交不一致：$HEAD_SHA" >&2; exit 1; }

# 原内核链接遵循 kernel_platform/<kernel> + vendor 布局。
# 只检出这些真实链接引用的 OEM 子树，保留内核中的原始链接字节。
python3 "$ROOT_DIR/自动化测试矩阵/host/kernel_dependencies.py" fetch --kernel "$TARGET"

echo "   已就绪: $TARGET"
echo "   HEAD:   $HEAD_SHA"
echo "   版本:   $(grep -m1 '^VERSION' "$TARGET/Makefile") $(grep -m1 '^PATCHLEVEL' "$TARGET/Makefile") $(grep -m1 '^SUBLEVEL' "$TARGET/Makefile")"
echo
echo "下一步：见《THIRD-PARTY-NOTICES.md》§1.4「编译」"
