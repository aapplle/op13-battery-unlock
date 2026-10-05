#!/system/bin/sh
# 只卸载内核模块（不碰文件、不重启）—— 用于确定性复现"卸载后 vbat_uv 变 2800"
rmmod uv2800 2>/dev/null
echo "rc=$?"