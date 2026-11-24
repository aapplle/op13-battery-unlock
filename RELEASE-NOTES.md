# 一加 13 解容模块 uv2800 v12.2 发布说明

`v12.2`（`version=12.2` / `versionCode=37`）是一个关键修复版本，解决 `v12` 后期 / `v12.1` 在设定关机电压（如 `2800 mV`）后跌破阈值仍延迟至约 `2600 mV` 才关机的问题，并修复 `v12.1` 审计发现的读写锁争用与壳层读值残留两处缺陷。跨 ColorOS 15 / 16 / 17 与 GKI 6.6.30~6.6.118 免重编兼容性保持不变。

---

## 一、核心修复：解决低电 `ui_soc` 卡死 2% 延迟关机（`uv2800.c` / `uv2800.ko`）

- **问题根因**：驱动 `oplus_comm_ui_soc_update_work` 中的 `keep_soc_2` 防掉电守卫以 `GAUGE_TERM_VOLTAGE + 30 mV` 作为阈值。`v12.1` 将 `GAUGE_TERM_VOLTAGE` 覆写为派生学习值 `2540 mV` 后，`keep_soc_2` 阈值被拉低至 `2570 mV`，导致电压跌破 `2800 mV` 触发低电倒计时后仍被强行锁回 `ui_soc = 2%`，直到电压跌至 `2600 mV` 附近才放行关机。
- **修复方案**：
  - 将 `GAUGE_TERM_VOLTAGE` 覆写值对齐至 `uv_target_mv`（`V_s`，如 `2800 mV`），与 `GAUGE_SHUTDOWN_VOLTAGE` / `TARGET_SHUTDOWN_VOLTAGE` 一致，使 `keep_soc_2`（`2830 mV`）与 `low_battery_control` 不再阻断按设定电压关机；
  - 保留 ADSP 侧与 `kp_term_get` / `kp_term_set` / `adsp_write` 路径为派生学习值 `uv_term_mv`（`2540 mV`），确保 ADSP 继续按写入值调节电量计算模型；
  - `TARGET_TERM_VOLTAGE` 保持为 `uv_term_mv`（`2540 mV`），与 `kp_term_get` 读出值一致，避免 `oplus_gauge_get_ddrc_status` 误判漂移并重复写入 `last_cc`。

---

## 二、v12.1 审计回归修复

1. **拆分 `adsp_read` 与 `adsp_write` 原子锁（`uv2800.c`）**：
   - 将原先共用的单把 `uv_adsp_busy` 拆分为独立的 `uv_adsp_read_busy` 与 `uv_adsp_write_busy`（仍采用零外部符号的编译器内建原子原语，严格维持 9 符号最小 KMI 集），消除 WebUI 状态轮询（`adsp_read`）与 `service.sh` / `restore.sh` / `write-adsp` 写入（`adsp_write`）并发冲突返回 `-EBUSY` 的隐患。
2. **修复 `_uv_read_trimmed()` 读失败泄漏旧值（`lib/common.sh`）**：
   - 在 `IFS= read -r _uvrt_v < "$1"` 前显式清空 `_uvrt_v=""`，杜绝文件打开/读取失败时因残留上一次读值导致 `[ -n "$_uvrt_v" ]` 误判成功的回归，并在 [自动化测试矩阵/dev/webui_host_smoke.sh](自动化测试矩阵/dev/webui_host_smoke.sh) 补充对应回归断言。

---

## 三、构建与自检摘要

- `uv2800.ko`：`vermagic=6.6.118-4k-g6028f47fadda`，`.gnu.linkonce.this_module=000600`，KMI 符号严格保持最小 7 项（`module_layout`、`_printk`、`register_kprobe`、`unregister_kprobe`、`kstrtoint`、`__stack_chk_fail`、`param_ops_bool`）。
- 宿主侧语法自检（`sh -n`、`node --check`）、[自动化测试矩阵/dev/webui_host_smoke.sh](自动化测试矩阵/dev/webui_host_smoke.sh)（18 项断言全部 PASS）与 [自动化测试矩阵/dt_inject/run_cases.py](自动化测试矩阵/dt_inject/run_cases.py)（13/13 PASS）全部通过。
