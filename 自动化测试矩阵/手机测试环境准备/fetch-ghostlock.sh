#!/usr/bin/env bash
# ============================================================
# fetch-ghostlock.sh —— 按需拉取 GhostLock 官方 release 资产
#
# 本仓库【不再分发】GhostLock 的二进制与 APK，改为本脚本从官方 release
# 下载并比对官方 SHA256。详见仓库根《THIRD-PARTY-NOTICES.md》。
#
# 上游 : YuKongA/ghostlock-app   https://github.com/YuKongA/ghostlock-app
# 许可 : Apache-2.0
# 版本 : release "pre-release" = v1.2 (549)
#        commit ff9991b1c33b6e0d0faa60c48658410974b11791
#
# 用法:
#   ./fetch-ghostlock.sh                  # 下载 3 个资产到 ghostlock-越狱工具/ 并校验
#   ./fetch-ghostlock.sh --verify         # 只校验已存在的文件（不下载）
#   ./fetch-ghostlock.sh --with-profiles  # 额外拉官方 kernel-profiles 包到 profiles-官方/
# ============================================================
set -uo pipefail

REPO="YuKongA/ghostlock-app"
TAG="pre-release"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$HERE/ghostlock-越狱工具"

VERIFY=0; WITH_PROFILES=0
for a in "$@"; do case "$a" in
  --verify) VERIFY=1 ;;
  --with-profiles) WITH_PROFILES=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "未知参数: $a"; exit 2 ;;
esac; done

# name|size|sha256|execbit  —— SHA256 取自该 release 的 sha256sum.txt
ASSETS=(
  "ghostlock|240696|4197e2618dbfe12f1614fdf6f933b5adec59a2e82dd3add5ec2306ddf494a95e|1"
  "ghostlock-extract-linux-x86_64|4536568|650a0e065f679853bbd96b8973a0181c63a9ad6367fdb6593e55e8efd8bb3d3c|1"
  "GhostLock-release.apk|2493748|0c7dd5801e172a74b0ae6808825aaf8bd00edbcadd30063ef9c380fc129845cb|0"
)
PROFILES="GhostLock-kernel-profiles.zip|68497|be693e46c1466ebf1a5e30364b5a7c2b35a2fcddff367b31e8e0ceff44b047a7"

mkdir -p "$KIT"
FAIL=0

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

check() {   # name expected_sha
  local f="$KIT/$1" want="$2" got
  [ -f "$f" ] || { echo "  ✗ $1 缺失"; return 1; }
  got="$(sha_of "$f")"
  if [ "$got" = "$want" ]; then echo "  ✓ $1  $got"; return 0; fi
  echo "  ✗ $1  期望 $want  实际 $got"; return 1
}

echo "== GhostLock 资产（${REPO} @ ${TAG}）=="
for spec in "${ASSETS[@]}"; do
  IFS='|' read -r name size sha execbit <<<"$spec"
  if [ "$VERIFY" = 1 ]; then check "$name" "$sha" || FAIL=1; continue; fi
  if [ -f "$KIT/$name" ] && [ "$(sha_of "$KIT/$name")" = "$sha" ]; then
    echo "  ✓ $name 已存在且校验通过"; continue
  fi
  echo "  ↓ 下载 $name（$size B）..."
  if ! curl -fL --retry 3 --connect-timeout 20 -o "$KIT/$name.part" "$BASE/$name"; then
    echo "  ✗ 下载失败：$BASE/$name"; rm -f "$KIT/$name.part"; FAIL=1; continue
  fi
  mv -f "$KIT/$name.part" "$KIT/$name"
  [ "$execbit" = "1" ] && chmod +x "$KIT/$name"
  check "$name" "$sha" || FAIL=1
done

if [ "$WITH_PROFILES" = 1 ]; then
  IFS='|' read -r pn psz psha <<<"$PROFILES"
  OUT="$KIT/profiles-官方"
  mkdir -p "$OUT"
  echo "  ↓ 下载 $pn（$psz B）..."
  if curl -fL --retry 3 --connect-timeout 20 -o "$OUT/$pn" "$BASE/$pn" && [ "$(sha_of "$OUT/$pn")" = "$psha" ]; then
    ( cd "$OUT" && unzip -oq "$pn" ) && echo "  ✓ 已解压到 ghostlock-越狱工具/profiles-官方/"
  else
    echo "  ✗ $pn 下载或校验失败"; FAIL=1
  fi
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "✅ 全部就绪。下一步：./恢复到手机.sh --dry-run"
else
  echo "❌ 有资产缺失或校验不符，见上。"; exit 1
fi
