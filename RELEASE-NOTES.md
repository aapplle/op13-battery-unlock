# 一加 13 解容模块 uv2800 v12.1 发布说明

`v12.1`（`version=12.1` / `versionCode=36`）是 `v12` 之后的健壮性加固与性能优化版本，聚焦内核安全边界、用户态并发与状态复核准确性、WebUI 轮询性能以及开源仓库自动化自检，核心行为与跨 ColorOS 15 / 16 / 17 兼容性完全延续 `v12`。

---

## 一、内核模块健壮性加固（`uv2800.c` / `uv2800.ko`）

1. **加载失败路径完整回滚**：新增 `uv_unregister_all()`，当必需的 `kp_get` / `kp_show` 注册失败时自动逆序反注册先前已注册的所有 kprobe，消除模块初始化失败导致残留探针的潜在风险。
2. **线程级自读写隔离与并发串行化**：
   - 将全局 `uv_self_read` / `uv_self_write` 升级为按 `current` 线程指针隔离，配合编译器内建原子锁与 `READ_ONCE` / `WRITE_ONCE` 串行化 `adsp_read` 与 `adsp_write`，防止驱动并发调用意外绕过 hook 或多线程互清标志。
   - 严格保持 `编译前置/Module.symvers` 的 9 符号最小 KMI 集（零新增外部符号，跨 GKI 6.6.30~6.6.118 免重编加载）。
3. **错误码与参数语义收敛**：
   - `adsp_write` 越界返回 `-EINVAL`、未捕获设备指针返回 `-EAGAIN`、驱动返回负错误码时如实透传且不污染 `uv_last_volt`；
   - `adsp_read` 严格按 `< 0` 判定驱动错误（兼容驱动成功时返回正值电压），失败时清零缓存避免返回陈旧值；
   - 新增 `uv_initialized` 标志防止加载期传参在 Profile 匹配前抢跑 `votable override`；`resume=0` 同步清除 override、`resume=1` 重放 override；
   - 修复 `uv_itoa_raw()` 对 `INT_MIN` 的有符号整数溢出边界，移除 4 个只写不读的冗余全局变量。

---

## 二、用户态脚本修复与 WebUI 轮询提速

1. **WebUI 状态采集提速约 5 倍**：
   - [模块源目录/lib/common.sh](模块源目录/lib/common.sh) 改用 POSIX 内建 `read` 与参数展开读取单行 sysfs / 状态文件，减少数十次外部子进程 fork；
   - 单趟 `awk` 提取日志 `route` / `profile` / `log_lines`（优先复用日志中的 `profile` 避免高频扫 `dmesg`，并规避 Android `mksh` 参数展开对未转义 `|` 的 extglob 解释）；
   - `_uv_fcc_read()` 对 `dmesg`（`bs`）与 `oplus_mms`（`mms`）两种真值来源均启用 60 秒缓存，并修复读取 `oplus_mms` 后原始 `item_id=0` 未恢复的问题。
2. **状态复核与并发安全修复**：
   - `_uv_derived()` 改为纯公式派生（统一复用 [模块源目录/log.sh](模块源目录/log.sh) 的 `uv_derive_term_mv()`），不再回读旧内核 `uv_term_mv`，消除复核假绿；
   - `webui.sh run-bg` 配合前端独立递增 tag（`status_<seq>` / `op_<seq>`），输出先写 `.out.tmp` 再原子重命名为 `.out` 后落盘 `.rc`，自动清理先前已完成但未被消费的孤儿文件；修复 `write-adsp` 的 `RC=` 键名冲突；
   - `service.sh` 清理旧进程时豁免完整祖先 PID 链，避免误杀外部调用壳；精简 `service.sh` / `restore.sh` / `uninstall.sh` 的重复内核参数四连写为单写 `uv_target_mv`；
   - `lib/lock.sh` 关闭 `mkdir` 到写 `pid` 间的瞬时抢锁窗口；`log.sh` 日志截断改用带 PID 后缀的临时文件；`uninstall.sh` 补充清理 `.webui_op.*` / `.webui.last.log` / `.webui.lock`。
3. **WebUI 交互与文案完善**：
   - 当 `adsp_orig.txt` 已有合法原厂值（3000~5000 mV）时，历史残留的 `adsp_orig.bad` 仅作为信息提示展示，不再永久屏蔽绿色正常状态横幅；
   - 补全 `CODE_TEXT` 缺失错误码映射（`invalid_range`、`readback_mismatch`、`override_failed`、`usage`），修正 `NO_ADSP_WRITE` 的按钮禁用范围与刷新 toast 触发时机。

---

## 三、开源仓库测试链路修复与 CI 加固

- 修复 [自动化测试矩阵/dev/webui_host_smoke.sh](自动化测试矩阵/dev/webui_host_smoke.sh)（扩充至 16 项断言）、[自动化测试矩阵/dt_inject/run_cases.py](自动化测试矩阵/dt_inject/run_cases.py) 与 [自动化测试矩阵/dt_inject/mk_v0order_variant.py](自动化测试矩阵/dt_inject/mk_v0order_variant.py) 路径解析，在开源仓库结构下可直接一键运行通过。
- [.github/workflows/release.yml](.github/workflows/release.yml) 接入打包前离线自检（`sh -n`、`node --check`、`webui_host_smoke.sh`、`dt_inject/run_cases.py`）。
- 清理仓库中多余的 `uvprobe` 编译中间产物与实验临时脚本，更新 `.gitignore` 与技术文档。
- 一加 13（ColorOS 16 / 内核 `6.6.118` / 标准 LKM 路线）实机回归测试全部通过（`run.sh --with-dt` 非重启组 + 宿主离线测试 **PASS 25 · FAIL 0**，WebUI 在线调压与功能开关端到端验证通过）。
