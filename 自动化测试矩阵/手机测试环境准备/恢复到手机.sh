#!/usr/bin/env bash
# ============================================================
# 恢复【矩阵运行必需】的手机文件（双清 / 换 ROM / 换内核后用）
#
#   推到 /data/local/tmp/：
#     ghostlock    越狱 CLI（run.sh 的 JAILBREAK_CMD 依赖）
#     profile.bin  ghostlock 预置 profile（--load-prebuilt-profile 的入参）
#
#   ⚠️ profile.bin **绑内核 release**（CLI 强制校验，--force-attack 也绕不过）。
#      所以本脚本**按设备当前 uname -r 自动挑**，挑不到就现场生成：
#
#   ./恢复到手机.sh                            按设备内核自动挑 profiles/<uname -r>.bin
#   ./恢复到手机.sh --dry-run                  只打印将执行的动作
#   UV_PROFILE=/path/x.bin ./恢复到手机.sh      指定 profile（仍会校验 release 是否匹配）
#   UV_BOOTIMG=/path/boot.img ./恢复到手机.sh   现场生成：官方提取器 → glk1_gen → 推送
#   UV_SERIAL=<serial>                         指定设备（默认取第一个 USB 设备）
#
#   现场生成用的 boot.img：优先用本地已抽好的副本
#     <EXTERNAL>/厂商驱动与固件/boot_imgs/（6 份，覆盖各内核 release）
#   生成原理与注意事项见 ghostlock-越狱工具/README.md
#
# 前提：手机已 root（KSU 管理器 APK 已安装并授权）—— ghostlock 注入时要拿
#       APK 里的 lib/arm64/libksud.so，没有 APK 它找不到 ksud。
# ============================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$HERE/ghostlock-越狱工具"
DEVBAK="$HERE/设备文件/data/local/tmp"
DRY=0
for a in "$@"; do case "$a" in
  --dry-run) DRY=1 ;;
  *) echo "未知参数: $a"; exit 2 ;;
esac; done

DEV="${UV_SERIAL:-$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')}"
[ -n "$DEV" ] || { echo "✗ 找不到 adb 设备"; exit 2; }
adb_() { timeout 120 adb -s "$DEV" "$@"; }
run()  { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else eval "$*"; fi; }

echo "设备: $DEV"

# ---------- 确保 GhostLock 官方二进制就位（不随仓库分发，按需拉取）----------
if [ ! -x "$KIT/ghostlock" ] || [ ! -x "$KIT/ghostlock-extract-linux-x86_64" ]; then
  if [ "$DRY" = 1 ]; then
    echo "⚠️  GhostLock 二进制未就位（--dry-run 不下载）—— 正式执行前请先跑："
    echo "      ./fetch-ghostlock.sh"
  else
    echo "GhostLock 二进制未就位，先从官方 release 拉取 ..."
    bash "$HERE/fetch-ghostlock.sh" || { echo "✗ fetch-ghostlock.sh 失败"; exit 2; }
  fi
fi
if [ "$DRY" = 0 ]; then
  [ -x "$KIT/ghostlock" ] || { echo "✗ 缺 ghostlock CLI：$KIT/ghostlock（先跑 ./fetch-ghostlock.sh）"; exit 2; }
fi

# ---------- 设备内核 release（决定用哪份 profile）----------
KREL="$(adb_ shell uname -r 2>/dev/null | tr -d '\r\n')"
echo "内核: ${KREL:-（读取失败）}"

# ---------- 选 profile ----------
PROF=""
if [ -n "${UV_PROFILE:-}" ]; then
  PROF="$UV_PROFILE"
  echo "profile: 使用 UV_PROFILE 指定 → $PROF"
elif [ -n "${KREL:-}" ] && [ -f "$KIT/profiles/$KREL.bin" ]; then
  PROF="$KIT/profiles/$KREL.bin"
  echo "profile: 命中本内核现成档 → ghostlock-越狱工具/profiles/$KREL.bin"
elif [ -n "${UV_BOOTIMG:-}" ]; then
  [ -f "$UV_BOOTIMG" ] || { echo "✗ UV_BOOTIMG 不存在: $UV_BOOTIMG"; exit 2; }
  BASE="$(ls "$KIT"/profiles/*.bin 2>/dev/null | head -1)"
  [ -n "$BASE" ] || { echo "✗ profiles/ 里没有可作为基准的 .bin"; exit 2; }
  echo "profile: 现场生成（官方提取器 → glk1_gen）"
  echo "  基准: ${BASE#$HERE/}"
  echo "  镜像: $UV_BOOTIMG"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  if [ "$DRY" = 1 ]; then
    echo "  [dry] ghostlock-extract-linux-x86_64 '$UV_BOOTIMG' --format conf --out $TMPD/new.conf"
    echo "  [dry] python3 tools/glk1_gen.py '$BASE' $TMPD/new.conf $TMPD/profile.bin"
    PROF="$TMPD/profile.bin"
  else
    "$KIT/ghostlock-extract-linux-x86_64" "$UV_BOOTIMG" --format conf --out "$TMPD/new.conf" || { echo "✗ 提取失败"; exit 2; }
    python3 "$KIT/tools/glk1_gen.py" "$BASE" "$TMPD/new.conf" "$TMPD/profile.bin" || { echo "✗ 生成失败"; exit 2; }
    PROF="$TMPD/profile.bin"
    # 存档：按 <uname -r>.bin 命名，下次直接命中
    if [ -n "${KREL:-}" ]; then
      cp "$TMPD/new.conf" "$KIT/profiles/$KREL.conf" 2>/dev/null
      cp "$PROF"          "$KIT/profiles/$KREL.bin"  2>/dev/null \
        && echo "  ✓ 已存档 → ghostlock-越狱工具/profiles/$KREL.bin（下次自动命中）"
    fi
  fi
elif [ -f "$DEVBAK/profile.bin" ]; then
  PROF="$DEVBAK/profile.bin"
  echo "⚠️  profiles/ 里没有本内核（$KREL）的档，退回设备侧快照：设备文件/data/local/tmp/profile.bin"
  echo "    若它绑的内核与设备不符，CLI 会直接拒绝 —— 请改用 UV_BOOTIMG 现场生成。"
else
  echo "✗ 找不到可用于本内核（$KREL）的 profile"
  echo "  → 取对应 ROM 的 boot.img（本地副本在 <EXTERNAL>/厂商驱动与固件/boot_imgs/），然后："
  echo "      UV_BOOTIMG=<boot.img> $0"
  echo "  原理见 ghostlock-越狱工具/README.md"
  exit 2
fi

# ---------- 校验 profile 的 release 与设备是否一致 ----------
if [ "$DRY" = 0 ] && [ -f "$PROF" ]; then
  PR="$(python3 "$KIT/tools/decode_glk1.py" "$PROF" 2>/dev/null | sed -n "s/^release='\(.*\)'/\1/p")"
  echo "profile release: ${PR:-（解码失败）}"
  if [ -n "${PR:-}" ] && [ -n "${KREL:-}" ] && [ "$PR" != "$KREL" ]; then
    echo "✗ profile 绑的内核（$PR）与设备（$KREL）不一致 —— CLI 会拒绝，已中止"
    exit 2
  fi
fi

# ---------- 前置检查：KSU 是否在位（ghostlock 要从 APK 取 libksud.so）----------
ksu_n="$(adb_ shell "pm list packages 2>/dev/null | grep -cE 'kernelsu|resukisu|supermanager'" 2>/dev/null | tr -d '\r ')"
if [ "${ksu_n:-0}" = "0" ]; then
  echo "⚠️  没检测到 KSU 管理器（kernelsu/resukisu/supermanager）—— ghostlock 要从它的"
  echo "    lib/arm64/libksud.so 取 ksud，请先装好 APK 并授权，否则越狱路线不可用"
else
  echo "✓ 检测到 KSU 管理器（$ksu_n 个匹配包）"
fi

# ---------- 推送 ----------
echo ""
echo "── 推送 → /data/local/tmp/"
run "adb_ push '$KIT/ghostlock' /data/local/tmp/ghostlock >/dev/null 2>&1" && echo "  ✓ ghostlock（ghostlock-越狱工具/）"
run "adb_ push '$PROF' /data/local/tmp/profile.bin >/dev/null 2>&1" && echo "  ✓ profile.bin"
run "adb_ shell 'su -c \"chmod 755 /data/local/tmp/ghostlock; chmod 666 /data/local/tmp/profile.bin\"' >/dev/null 2>&1"

# ---------- 校验：本地 ↔ 设备 md5 互算比对（不写死期望值）----------
echo ""
echo "── 校验（本地 ↔ 设备 md5 比对）"
if [ "$DRY" = 0 ]; then
  for pair in "$KIT/ghostlock:/data/local/tmp/ghostlock" "$PROF:/data/local/tmp/profile.bin"; do
    l="${pair%%:*}"; r="${pair##*:}"
    lm="$(md5sum "$l" | cut -d' ' -f1)"
    dm="$(adb_ shell "su -c 'md5sum $r'" 2>/dev/null | tr -d '\r' | cut -d' ' -f1)"
    if [ "$lm" = "$dm" ]; then echo "  ✓ $r  $lm"
    else echo "  ❌ $r  本地 $lm  设备 ${dm:-缺失}"; fi
  done
  echo "  CLI 自检："
  adb_ shell 'su -c "/data/local/tmp/ghostlock --help"' 2>&1 | head -2 | sed 's/^/    /'
fi
echo ""
echo "完成。下一步：cd \"$(dirname "$HERE")\" && ./run.sh"
