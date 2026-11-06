# uv2800 v12

- 原生 KernelSU WebUI，统一状态查看与操作入口。
- 关机电压 V_s 与 QBG 学习 term 分离；term 按 v11 公式动态派生。
- 修复恢复原厂时 term/votable 被派生值覆盖的问题。
- 真实 FCC 改为优先读取 QBG item 7，并标注真值/显示值。
- 完整 late-load / LKM 回归测试。
