#!/system/bin/sh
# 软重启（KernelSU）。找不到 ksud 时输出 NO_KSUD，由主机侧判为 SKIP
for p in /data/adb/ksu/bin/ksud /data/local/tmp/ksud; do
  [ -x "$p" ] && { "$p" soft-reboot >/dev/null 2>&1; exit 0; }
done
if command -v ksud >/dev/null 2>&1; then ksud soft-reboot >/dev/null 2>&1; exit 0; fi
K=$(find /data/app -path '*kernelsu*/lib/arm64/libksud.so' 2>/dev/null | head -1)
[ -n "$K" ] && { "$K" soft-reboot >/dev/null 2>&1; exit 0; }
echo NO_KSUD; exit 1
