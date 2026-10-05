# uv2800 全场景自动化回归测试

> **给子代理**：你只需要会跑 `自动化测试矩阵/run.sh` 这一个文件。
> 不要手改设备状态 —— 用例内部自己会 setup/teardown。

---

## ⚡ 我该跑哪个？—— 本目录脚本地图

**"跑全量测试" = `./run.sh`（路线自动判定）+ 标准路线下加 `--with-reboot`。就这一个入口。**

| 命令 | 是什么 | 什么时候用 |
|---|---|---|
| **`./run.sh`** | **唯一测试入口**（自动判定 standard / late-load，按路线跑该跑的全部用例） | **跑全量**（late-load 越狱下这一条就是全量） |
| **`./run.sh --with-reboot`** | 同上 + 标准路线下把「需重启」用例也跑完（**standard 下的最全覆盖**） | **standard/LKM 下跑全量** |
| `./run.sh T1 T2 T6` | 只跑指定组或单个用例（用例 ID 前缀匹配） | 调试 / 复测某个组 |
| `./run.sh --list` | 列出全部用例与路线适用性 | 先看有什么 |
| `./run.sh --with-dt` | 额外跑**可选组 TD**（宿主侧失败注入，默认不跑、不影响计数） | 改过 `uv_dt_orig()` 之后 |
| `./build.sh` | **不是测试** —— 从源码编译 `.ko` 并按 `module.prop` 打包 zip | **改过源码/脚本后必须先跑它**，否则测的还是旧包 |
| `dev/*.sh` | 设备侧**原子操作**（snap / apply / set / route / softreboot…），被 `run.sh` 调用 | 手工排查时单独调（见 §4） |
| `dt_inject/` | 可选组 TD 的测试资产（13 例断言 + 哨兵，位置无关） | 算法层改动后的秒级验证 |
| `手机测试环境准备/` | 越狱环境套件：`ghostlock-越狱工具/`（CLI + profile 生成器 + 各内核 profiles）、`恢复到手机.sh` | 双清/换 ROM/换内核后恢复；**本内核没有 profile 时用它现场生成** |

> **本目录只有一个测试入口：`run.sh`。** 判定标准：文件头写着「唯一入口」，且 `./run.sh --list` 能列出全部用例。
> 命名形似入口的其它文件（历年出现过跑分器副本、子集副本、边缘矩阵执行器等）一律视为历史遗留 ——
> 需要旧版时到 `<EXTERNAL>/历史版本归档/会话遗留-20261005/` 找。

---

## 0. 被测模块：**v11**（versionCode 34）

本框架测的是 **`一加13解容-v11.zip`**（version=11 / versionCode=34；
构建 md5 见每次报告头部，2026-10-05 全量验证时为 `87c59ee7b5335a4ca5afc248d5d6f00b`）。

> **命名说明**：v11 是大版本命名，只递增 `versionCode`；旧的 v11.0/v11.1/v11.2 包已全部归档到
> `<EXTERNAL>/历史版本归档/历史zip/`（清单见该目录 `MANIFEST-v11系列.txt`）。
>
> **`.ko` 自 v11 起逐字节未变**（md5 `7b75bdd90502eca14dc7f4e7509f528b`），历史版本改的都是脚本：
> ① `post-fs-data.sh`/`late-load.sh` 在 insmod 后把内核自报的 `profile=[...]` 落盘到 `uv2800.log`
> （dmesg 约 10 分钟就被冲掉，跨 ROM 矩阵原本拿不到）；
> ② `late-load.sh` 接入公共日志（此前只有裸 echo，越狱路线日志里看不到它执行过）。
> 因此**审计报告里对内核模块二进制的全部结论（§2/§3/§3c）原样适用**。

**改了源码后必须先重新构建**，否则测的还是旧包：

```sh
cd 自动化测试矩阵
./build.sh                 # 从当前源码编译 .ko + 按 module.prop 打包（覆盖前自动备份 .prev）
```

框架启动时会**自动比对**设备上已装版本与 `UV_ZIP` 版本，不一致就卸载重装（保证测的是被测构建）。

## 0.5 手机测试环境准备（**双清 / 换机前必看**）

矩阵依赖**手机上的文件**（`/data/local/tmp/ghostlock`、`profile.bin`、
`/data/adb/uv2800_backup/` 等），而这些都在 `/data` 与 `/sdcard` —— **双清会全部清掉**。

`自动化测试矩阵/手机测试环境准备/` **只保留矩阵运行必需的两个文件**（296 KB，md5 已校验）：

| 文件 | 恢复到 | 用途 |
|---|---|---|
| `ghostlock` | `/data/local/tmp/` | 越狱 CLI（`run.sh` 的 `JAILBREAK_CMD`） |
| `profile.bin` | `/data/local/tmp/` | ghostlock 预置 profile |

其余都不需要备份：ghostlock 的运行时产物（`.ghostlock_iomem` / `.ghostlock_root.sh`）**它自己每次重新生成**
（且 iomem 缓存**绑内核版本**）；`/data/adb/**` 由 KSU 与 `run.sh` 自动重建；`uvtest/**` 每次运行自动推送。

双清后一键恢复（**前提：已重新 root + 装好 KSU APK**）：

```sh
cd 自动化测试矩阵/手机测试环境准备
./恢复到手机.sh --dry-run   # 先看要干什么
./恢复到手机.sh             # 推回 ghostlock + profile.bin 并校验 md5
```

细节（清单、原始权限、双清后完整恢复顺序）见该目录的 `README.md`。

## 1. 快速开始

```sh
cd 自动化测试矩阵

./run.sh --list            # 先看有哪些用例（第三列是路线适用性）
./run.sh T1 T2 T6          # 只跑指定组（快，不重启，约 2~3 分钟）
./run.sh                   # 按【自动判定的启动路线】跑该路线的用例集
./run.sh --with-reboot     # 标准启动路线下也跑「需重启」用例（默认跳过）
./run.sh --no-reboot       # 跳过所有需要重启的用例
./run.sh --resume          # 续跑：跳过【上次已 PASS】的用例（被催/中断后用这个）
```

> **跑之前先看它选了哪一支**：启动时第一行会打印
> `启动路线: standard（来源 log）` 或 `late-load`，并列出被判为不适用而 SKIP 的用例及原因。
> 判错了用 `UV_ROUTE=standard` / `UV_ROUTE=late-load` 强制覆盖。

**耗时分布**（实测）：

| 组 | 内容 | 耗时 |
|---|---|---|
| T0+T1+T2 | 状态检查 / 解耦 / 点执行 | ~2 min |
| T6+T8 | 自定义关机电压 / 边界 | ~1 min |
| T3 | 2 次软重启 | ~2 min |
| T4 | 2 次硬重启 + 越狱 | ~5 min |
| T7.2 | 卸载 + 软重启 + 重装 | ~3 min |
| T10 | 标准启动专属（4 项，不重启） | <1 min |

**两种跑法的实测耗时**：

**T0–T10 共 33 个用例**（另有可选组 TD 2 个，默认不计入；加 `--with-dt` 才是 35）。
下列数字由 `run.sh` 的 `#CASE` 适用范围直接统计得出：

| 命令 | 跑 / SKIP | 耗时（实测） |
|---|---|---|
| `./run.sh`（标准启动路线，需重启项全 SKIP） | **23 跑 + 10 SKIP = 33** | ~6 min |
| `./run.sh`（late-load 越狱路线，全量） | **28 跑 + 5 SKIP = 33** | ~15 min |
| `./run.sh --with-reboot`（标准启动 + 重启组） | **31 跑 + 2 SKIP = 33** | ~25 min |

**环境变量**（都有默认值，通常不用给）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `UV_SERIAL` | 自动取第一个 USB 设备 | 设备序列号 |
| `UV_ROUTE` | **自动判定** | 强制启动路线：`standard` / `late-load`。自动判定失败（日志里两个标记都没有）时会要求你显式指定 |
| `UV_FLOOR` | **`3060`** | ADSP 派生用的 floor。**规格值 = 3060**（= 新机原厂关机电压 = 电量计模型计数下限） |
| `UV_ZIP` | **`../一加13解容-v11.zip`**（仓库根） | **被测构建**（v11 / versionCode 34）。设备版本 ≠ 此 zip 版本时，框架会自动卸载重装 |

**退出码**：`0` = 全 PASS 或全 SKIP；`1` = 有 FAIL。
**结果**：`results/<时间戳>/{report.json, report.jsonl, report.md, logs/}`

---

## 1.5 启动路线分支

同一份模块，**两种部署方式**下要验的东西不一样，矩阵因此分两支 —— 由 `dev/route.sh` 自动判定。

| 路线 | 部署方式 | 关键特征 |
|---|---|---|
| **standard** 标准启动 | KSU 在 `init_boot`，随 boot 加载 | `post-fs-data.sh` **会执行**；`uv_dev` 由**驱动开机 vote 自动捕获**；bind 在当前（全局）命名空间生效；`KSU_LATE_LOAD` 为空 |
| **late-load** 越狱注入 | ghostlock 用户态注入 | `post-fs-data.sh` **不执行**（由 `late-load.sh` 代替）；需要模块**主动触发 deep_dischg** 才捕获到 `uv_dev`；bind 需要 `nsenter -t 1 -m`；`KSU_LATE_LOAD=1` |

> ⚠️ **越狱路线并非所有机型都能走**：ghostlock 的注入方式在 C17（ColorOS 17 / 6.6.118）上不可用 ⇒
> 那些机器上 **T4.1/T4.2 记为"未实测"的 SKIP**（不是"该跑没跑"）。
> 工具与各内核 profile 见 `手机测试环境准备/ghostlock-越狱工具/`。

### 自动判定怎么做的（`dev/route.sh`）

只认两个**只可能由 KernelSU 自己产生**的标记：

| 标记 | 含义 |
|---|---|
| `post-fs-data.sh 开始` | 只有标准启动会跑这个阶段 |
| `KSU_LATE_LOAD=1` | 只有越狱注入会带这个环境变量 |

**三级判定（顺序即优先级）**：

| 级 | 条件 | `route_src` | 强度 |
|---|---|---|---|
| ① | 两个标记里有一个出现在 **`dmesg`** → 取 dmesg 中**较晚**的那个 | `dmesg` | **强**：dmesg 只属于**本次内核会话**，且天然按时间排序（软重启也不清空，新行排在旧行之后） |
| ② | dmesg 没命中，但**日志文件 mtime ≥ 开机时刻**（说明本次开机写过日志）→ 按日志行号取较晚者 | `log` | 弱：依赖"本次开机确实写过日志" |
| ③ | 都不满足 | `none` → **unknown，run.sh 直接终止** | — |

三个坑（都踩过）：
1. **不能**用「`KSU_LATE_LOAD` 为空」判标准启动 —— 测试用例自己会以主机身份 `sh service.sh`，那次的变量同样是空，会把越狱误判成标准。
2. **不能**只看日志行号 —— **模块被卸载 / 刚刷机时，`uv2800.log` 里只有上一轮开机的旧标记**，会直接把标准启动误判成 late-load（踩过：整支用例跑错）。必须先确认标记属于本次开机（上面的 ①/②）。
3. **也不能**把 `dmesg` 当唯一依据 —— 内核环形缓冲约 10 分钟就被冲掉（实测 uptime 11min 时 `[4.2s]` 之前的行全丢）。所以 dmesg 是**首选**、日志是**兜底**，两者互补。

判定结果会写进报告：`boot_route` / `route_src` / `route_evidence`（证据原文），另有 `log_fresh` / `boot_time` 便于排查。**判定不出来时会直接终止并要求用 `UV_ROUTE` 显式指定**，绝不猜。

### 软重启走的是 KSU 官方实现（不是自研模拟）

`dev/softreboot.sh` 只调 **`ksud soft-reboot`**（官方子命令：`Emulate system reboot`），
回退顺序是 `/data/adb/ksu/bin/ksud` → `/data/local/tmp/ksud` → APK 里的 `libksud.so`；
三个都找不到就输出 `NO_KSUD`，`run.sh` 把该用例记 **SKIP**，**绝不**用别的方式"假装重启"。

**为什么必须这样**：KSU 的 soft-reboot **不是简单 kill system_server**（`ksud` 里有 `userspace/ksud/src/soft_reboot.rs`，
字符串含 `emulating soft_reboot!` / `stop failed` / `waiting for services to stop`）——
它停掉服务后**重跑 post-fs-data 与 service 两个阶段**，模块脚本因此被重新执行。ksud 还把这些阶段做成显式入口：

| 入口 | 作用 |
|---|---|
| `ksud post-fs-data` / `ksud services` / `ksud boot-completed` | 单独触发某个阶段 |
| **`ksud late-load`** | "Load kernelsu.ko and execute late-load stage scripts" —— **越狱模式重新加载 `late-load.sh` 并跑 service 脚本靠的就是它** |

**反例**：只重启框架（`stop && start` / `ctl.restart zygote`）**不会**重跑模块脚本 →
越狱模式下 `service.sh` 就不会重新执行（bind mount / 恢复模式 / 电量计状态停留在旧值）。
所以**"越狱模式下软重启后模块仍完整"这件事，只有走 KSU 官方 soft-reboot 才成立**。
（硬重启当然也会重跑一切，但越狱模式硬重启后 KSU 本身没了，必须重新注入 ghostlock —— 这就是 T4.x 的流程。）

**实测佐证**（2026-10-05，标准模式 `--with-reboot` 全量，含 9 次软重启）：

```
post-fs-data 段数: 12      ← 每次软重启都重跑了 post-fs-data
service.sh 段数 : 29
late-load 段数  : 0        ← 标准模式本就不该跑 late-load.sh
[10-05 01:39:06] ---------- post-fs-data.sh 开始 ----------
[10-05 01:39:06] ---------- service.sh 开始（KSU_LATE_LOAD=） ----------
[07-22 11:59:40] ---------- post-fs-data.sh 开始 ----------   ← 07-22 = RTC 未同步 = T10.5 硬重启
[10-05 01:40:44] ---------- service.sh 开始（KSU_LATE_LOAD=） ----------
```

越狱模式的对应证据：路线判定那一行就是 `[812.824522] service.sh 开始（KSU_LATE_LOAD=1）` ——
内核 uptime **812 秒**（真实开机时模块还没装），说明它是**软重启时**由 KSU 以 late-load 上下文重跑的。

### 用例的路线适用性

写在各用例自己的 `#CASE <ID>|<名称>|<适用性>` 行，`./run.sh --list` 第三列可见：

| 适用性 | 含义 | 标准启动下 | 越狱下 |
|---|---|---|---|
| （缺省 `all`） | 两条路线都该过，且不需要重启 | 跑 | 跑 |
| `reboot` | 需要重启（软/硬重启） | **默认 SKIP**，`--with-reboot` 才跑 | 跑 |
| `late` | 越狱专属（T4.x：ghostlock 注入路径） | SKIP | 跑 |
| `std` | 标准启动专属（T10.x） | 跑 | SKIP |
| `std,reboot` | 两者都要（T10.5） | 默认 SKIP，`--with-reboot` 才跑 | SKIP |

**为什么标准启动默认不跑重启组**：这类用户不会没事软重启，重启组（T3/T5/T6.6/T7.2/T9.1/T9.2）在标准启动下的意义远低于越狱路线 —— SKIP 掉反而让报告更干净（每条 SKIP 都带原因，见 `report.md`）。

---

## 1.6 跨 ROM / 跨内核兼容性矩阵

刷完不同 ROM / 内核后，直接跑一次 `./run.sh`，报告**自带所有窗口信息**，不用另开文档记：

```sh
./run.sh                                     # → results/<时间戳>/
python3 dev/backfill_route.py --dry-run      # 只给【历史】结果补路线声明（幂等，已补的跳过）
```

对比不同批次（一条命令列出每份报告的窗口）：

```sh
for d in results/*/; do
  python3 -c "import json,sys;d=json.load(open('$d/report.json'));print('$d', d.get('boot_route'), d.get('device_rom'), d.get('device_kernel'), 'chgko='+str(d.get('device_chgko_md5'))[:8], 'PASS=%d FAIL=%d'%(d.get('pass',0),d.get('fail',0)))" 2>/dev/null
done
```

`report.json` 里用于矩阵比对的字段：

| 字段 | 含义 | 换 ROM/内核后为什么会变 |
|---|---|---|
| `boot_route` / `route_src` / `route_evidence` | 启动路线 + 判定依据原文 | 判错了先看这里 |
| `device_rom` / `device_oplusrom` / `device_android` | 系统版本 | ColorOS 15/16/17 |
| `device_kernel` | 内核 release | 6.6.30 / .89 / .118 |
| `device_chgko_md5` | **被 hook 的 `oplus_chg_v2.ko` md5** | 换 ROM/内核必变；hook 偏移是否仍匹配先看它 |
| `driver_profile` / `driver_hooks` | 模块自报的 profile（如 `[ColorOS 16/17]`）与 hook 数 | 版本自适应选中了哪一支；**dmesg 被冲掉时为 `?`** |
| `device_slot` / `device_vbstate` | 槽位 / 校验状态 | `_a`/`_b`、`orange` |
| `build md5`（`TESTED_MD5`） | 被测 zip md5 | 同一 ROM 换构建时区分 |

### 换 ROM 后值得单独看一眼：DT 的原厂终止电压策略表

**原厂终止电压不是常量，它由 DT 的两维查表算出**（表随 ROM 构建演进；同一台机实测 3060 → 3150 → 3250）。

❌ **常见误读（算不出终止电压）**：查 `deep_spec,term_coeff` 表、用 `deep_dischg_counts` 去比较、并以为"C15 后期=3350"。
`term_coeff` **只喂 ratio，不是电压来源**；3350 是模块旧版算错后写进 IC 的值，不是原厂值。
✅ 正确算法（驱动 `ddrc_strategy`，已代码级证实，详见 `文档/AUDIT-uv2800-v11-独立审计.md` §15 与
`文档/ISSUE-uv2800-DT兜底值错误(3250vs3350).md` §6.2）：

```
ratio   = 10 × deep_dischg_counts / cc        （cc = battery_cc = 循环次数）
region  = ratio 与 oplus,ratio_range[20,30,50,70,90] 比较（≥ 抬档）→ min/low/mid_low/mid/mid_high/high
index_t = 温度与 oplus,temp_range[-50,100,350] 比较（≤ 归下档）→ cold/cool/normal/warm
表      = <battery_type>/ddrc_strategy/strategy_ratio_range_<region>/strategy_temp_<温度>
行 k    = 最后一个满足 max(0, f0 − count_cali) ≤ cc 的行；输出第 3 个字段（终止电压）
```

**跨 ROM 实测差异（2026-10-05）**：C17 的 `min/low/mid_low` 三张表比 C16 **更低**（如 min 行 3 由 `(1000,3200,3250)` 变 `(1000,3150,3200)`），
`mid/mid_high/high` 相同 ⇒ **必须动态读表**，任何硬编码都会在 C17 上算错。C17 当前表已存档 `逆向脚本与产物/DT表/C17.0.0.101/`。

```sh
# 设备侧转储 + 手工核对（工具在 dev/ 下）
adb shell 'su -c "sh /data/local/tmp/uvtest/dtterm.sh"'   # 打印 term_coeff（ratio 用表）与生效项
```
> `dtterm.sh` 打印的是 **`term_coeff`（喂 ratio 的那张表）**，**不是**终止电压本体 —— 别拿它当原厂值。

> ⚠️ `driver_profile` **不要从 `dmesg` 抓**（内核环形缓冲约 10 分钟就被冲掉）。矩阵是这样拿到的：
> 模块自己的 `post-fs-data.sh`/`late-load.sh` 在 insmod 后把内核自报的 `profile=[...]`
> 落盘到 `/data/adb/uv2800_backup/uv2800.log`，矩阵直接从日志读，不再依赖 dmesg 时效。
> 万一是 `?`（老构建/日志被清），T1.2/T1.3/T6.x 全过也等价于「profile 匹配成功」—— hook 没注册上这些用例必挂。

---

## 2. 用例矩阵（场景 × 期望）

### T0 环境
| ID | 场景 | 期望 |
|---|---|---|
| T0.1 | 环境就绪 | adb + su 可用，模块已加载 |
| T0.2 | 快照采集 | 13 个关键 key 齐全 |

### T1 解耦态（skip 不存在 ⇒ **模块全部功能生效**）
| ID | 断言 |
|---|---|
| T1.1 | `uv_target_mv == V_s`（默认 2800）、`skip == no` |
| T1.2 | `vbat_uv == V_s`（**hook 即时镜像，无需插拔**）、`resume == 0` |
| T1.3 | `adsp_read == V_s − max(0, FLOOR−V_s)`（FLOOR=3060 → **2540**） |
| T1.4 | bind 层数 ≥1 且 `capacity == chip_soc` |
| T1.5 | 无残留后台进程 |

### T2 点「执行」（⇒ **完全恢复出厂**）
| ID | 断言 |
|---|---|
| T2.1 | `skip == yes` |
| T2.2 | `adsp_read == adsp_orig`（原厂值）、`adsp_state == adsp_orig` |
| T2.3 | `uv_target_mv == adsp_orig` |
| T2.4 | **`vbat_uv == adsp_orig` 立即生效（不插拔）**、`resume == 0` |
| T2.5 | bind 层数 == 0 |

### T3 软重启
| ID | 场景 | 期望 |
|---|---|---|
| T3.1 | skip 无 + 软重启 | 解耦态全项（T1.1~T1.4） |
| T3.2 | skip 有 + 软重启 | 出厂态全项（T2.2~T2.5） |

### T4 硬重启 + 越狱（**核心：零插拔**）
| ID | 场景 | 期望 |
|---|---|---|
| T4.1 | skip 无 | 解耦态全项 + **日志含「主动触发 deep_dischg」** |
| T4.2 | skip 有 | 出厂态全项 |

### T5 状态切换
| ID | 场景 | 期望 |
|---|---|---|
| T5.1 | 解耦态 touch skip + 重启 | `adsp_read` **被拉回原厂** |

### T6 ★ 自定义关机电压
| ID | target | 期望 ADSP（FLOOR=3060） |
|---|---|---|
| T6.1 | 2800 | **2540** |
| T6.2 | 2900 | **2740** |
| T6.3 | 3000 | **2940** |
| T6.4 | 3060 | **3060**（偏移归零） |
| T6.5 | 2799 / 3061 | 回退默认 2800 |
| T6.6 | 改 target + 软重启 | 生效并落盘 |

### T7 卸载路径（断言"模块清理完备"；**`vbat_uv` 只观察**）
| ID | 场景 | 断言 | 耗时 |
|---|---|---|---|
| T7.2 | 卸载 + 软重启 | 模块清理完备（`module_loaded==0`）；**`vbat_uv` 仅观察** | ~3 min |

> ### 卸载后 `vbat_uv` 为什么不能断言
>
> **三条路径，行为完全不同（均实测，见下方记录）**：
>
> | 路径 | 重启后 `vbat_uv` | 为什么 |
> |---|---|---|
> | **① 标准流程：先点「执行」→ 再卸载 → 重启** | **原厂值（本机 3250）** ✓ | 「执行」(`action.sh`) 已读实时 DT 算原值**写回电量计**并置 `skip`；KSU 卸载只是打 `remove` 标记，模块继续加载到下次开机，期间值也不变 |
> | ② 直接卸载（**不**先执行，卸载前仍是解耦态） | 驱动 DT 默认 **2800** | 解耦值没被回写；模块移除后由驱动/电量计自己回到默认，之后驱动 vote 才会重新发布 DT 原厂值 |
> | ③ 强制 `rmmod`（T7.2 用例主动做的就是这个） | **1 秒内 2800** | hook 随模块消失，驱动立即按 DT `deep_spec,uv_thr`(=2800) 重算，与 rmmod 前的值无关 |
>
> **实测记录（2026-10-06，C17.0.0.101 / 6.6.118，standard 路线）**
>
> ① **标准流程**（推荐）：
> ```
> 装 v11 → 硬重启 → 解耦态 target=2800 adsp=2540 vbat=2800
> 点「执行」→ target=3250 vbat=3250，skip=yes（日志：action.sh 恢复原值 开始 → 恢复完成：原值 3250 mV）
> ksud module uninstall uv2800
>   → /data/adb/modules/uv2800/remove 出现；lsmod=1（模块仍在跑）；vbat_uv 仍=3250
> 重启 → lsmod=0、模块目录消失
>   → vbat_uv=3250 ✓   skip=yes（保留，重装后仍为原厂态）   adsp_orig.txt=3250
>   → 驱动侧 dmesg：rm=4216 fcc=4216（补偿短路，干净状态）
> ```
>
> ② **直接卸载**（不先执行）：卸载后 `vbat_uv=2800`、模块目录同样要到下次开机才消失、`adsp_orig.txt` 仍保留 3250。
>
> ③ **强制 rmmod**：
> ```
> 前置：module=1  uv_target_mv=3250  vbat_uv=3250
> rmmod rc=0
> +1s  vbat_uv=2800     ← 与 rmmod 前的值无关；持续观察 12s 不变
> ```
>
> **关于 `uninstall.sh` 的执行时机**：它在**下次开机**才跑（日志时间戳 = 开机时刻；`ksud module uninstall` 当次只在模块目录打
> `remove` 标记，未跑任何脚本）。那时模块已不在内存 ⇒ 它"写原厂值"那段走不到（日志里也确无"已把 hook 强制值设为原厂"），
> 而它打印的"模块已禁用（未 rmmod，hook 保持生效）"是**无条件输出**、与事实不符。
> **在标准流程下这不影响结果**（值在"执行"那步已恢复），但脚本正文注释与这句提示应当更正。
> 卸载标记可以撤销：`ksud undo-uninstall uv2800`。
>
> **决定性实验（rmmod 路径）**：rmmod 前把 `uv_target_mv`/`vbat_uv` 特意设为 **3250** →
> ```
> 前置：module=1  uv_target_mv=3250  vbat_uv=3250
> rmmod rc=0
> +1s  vbat_uv=2800     ← 与 rmmod 前的值无关；持续观察 12s 不变
> ```
> 之后驱动会在**下一次开机 vote** 时按 DT `ddrc_strategy` 表重新发布原厂值（本机 3250）。
>
> **T7.2 为什么只观察**：该用例为了验"清理完备"，在 `ksud module uninstall` 之后**又主动 `rmmod`**（见 `run.sh` 的 `t_T7_2`），
> 走的是上表第二行 ⇒ 观察到的 2800 是**驱动行为**，不是模块残留，**不该断言**（断言它会变成永久 FAIL）。

### T8 边界
| ID | 场景 | 期望 |
|---|---|---|
| T8.1 | `adsp_orig.txt` 污染为 2500 | 拒绝该值（不回写）、生成 `.bad` 隔离文件 |

### T9 竞态 / 残留（`dev/racesnap.sh` 采集）
| ID | 场景 | 期望 | 适用性 |
|---|---|---|---|
| T9.1 | 连续软重启 ×3 | 无残留进程/僵尸、模块唯一、解耦态保持 | `reboot` |
| T9.2 | `rm skip` + **立即**重启 ×2 | 解耦态重建、模块唯一 | `reboot` |
| T9.3 | 并发竞态（3×`service.sh` + `action.sh`） | 收敛且状态自洽（skip 态三项一致 / 解耦态三件套） | all |

### T10 ★ 标准启动专属
| ID | 断言 | 适用性 |
|---|---|---|
| T10.1 | 路线判定 = `standard`，且判定来源是模块日志、KSU 模块在 `/proc/modules` | `std` |
| T10.2 | 本次开机跑过 `post-fs-data.sh` 且 `insmod rc=0`，模块已加载 | `std` |
| T10.3 | `adsp_read` 读得到（= `uv_dev` 已捕获）；**捕获方式只记录不断言**（见下方 T10.5 说明） | `std` |
| T10.4 | bind 方式 = **当前命名空间**（未走 `nsenter`）+ `capacity == chip_soc` | `std` |
| T10.5 | 硬重启（**不注入 ghostlock**）→ 仍是 standard、`post-fs-data` 仍执行、**冷启动无「主动触发 deep_dischg」（= 驱动开机 vote 自动捕获 `uv_dev`）**、解耦四件套保持 | `std,reboot` |

> **为什么「无主动捕获」只由 T10.5 断言**：那是**启动阶段**的性质，只有**真冷启动**才成立。
> KSU 软重启会重跑 `post-fs-data`（模块重新 insmod），但驱动的开机 vote 早在真开机时就发生过了
> —— 此时模块主动触发 `deep_dischg` 兜底才是**设计内的正确行为**，不是缺陷。
> **推论**：想验证这条路径，必须**先装好模块、再硬重启**；`rmmod`+`insmod` 或软重启之后测不了它。

---

### TD 可选组：`uv_dt_orig()` 失败注入（**宿主侧，默认不跑**）

| 用例 | 内容 | 适用性 |
|---|---|---|
| TD.1 | 13 例失败注入断言（表自检 / 项数 / 行数 / 电压区间 / 节点定位）；**断言本身纯宿主侧**（无设备实测 13/13 PASS，秒级） | `opt` |
| TD.2 | 哨兵自测：把已删除的 `v0_order` 检查注回副本，验证 `v0drop_ok` 用例**确实会 FAIL**（即"测试本身还有牙"） | `opt` |

> ⚠️ **"不需要设备"只对断言成立，不对 `run.sh` 成立**：`./run.sh` 会先做设备前置检查（连不上设备直接
> `✗ 找不到 adb 设备` 退出，TD 也跑不到）。**手机没连线时**请绕开外壳，直接跑
> `python3 dt_inject/run_cases.py`（实测无设备 13/13 PASS）；只有需要与其它用例一起出报告时才用下面三种方式。

开启方式（三选一，**默认不参与计数，因此不影响任何兼容性结论**；**均需设备在线**）：

```sh
./run.sh --with-dt      # 与其它用例一起跑
UV_DT=1 ./run.sh        # 等价
./run.sh TD             # 只跑这一组（只想验算法时用这个）
```

资产在 `自动化测试矩阵/dt_inject/`（位置无关，整体搬移不影响运行）：

| 文件 | 作用 |
|---|---|
| `run_cases.py` | 断言运行器（唯一入口，13 例） |
| `gen_dt.py` | 语料生成器（从 `base/` 真机基线派生 13 种注入） |
| `mk_v0order_variant.py` | 哨兵变体生成器（→ `/tmp/log_with_v0order.sh`） |
| `base/` | **自包含基线**（真机活 DT 的 `ddrc_strategy` 子树，27 文件） |
| `dtgen/` | 生成的语料（构建产物，可随时 `python3 gen_dt.py` 重建） |
| `_scratch_设备侧实验/` | 取证会话遗留的设备侧实验脚本，**不属于用例集**，仅存档 |

**直接跑单个用例 / 调试**（不经过 run.sh，秒级，无需设备）：

```sh
cd 自动化测试矩阵/dt_inject
python3 gen_dt.py                 # 重建语料（会清空 dtgen/）
python3 run_cases.py              # 跑全部 13 例并断言；退出码 0=全符合预期
python3 run_cases.py valid rr4    # 只跑指定用例
UV_DT_LOG=/path/to/log.sh python3 run_cases.py   # 换被测文件（哨兵就是这么用的）
```

**两个用例的独有价值**（别删）：
`v0drop_ok` 守的是**已修复的误拒**（真机表 `valid` 的 v0 单调递增，抓不到这个回归）；
`misparse12` 守的是**删掉 `v0_order` 后错位漏检**（12 B/行的表必须仍被 `volt_range` 拦下）。

**已知局限（务必知道，别让它背锅）**：
1. **纯宿主侧** —— 验的是"给定 DT 数据，算法行为对不对"，**不覆盖设备路径**（设备路径由 T0–T10 覆盖）；
2. **本组（宿主侧）不覆盖 C17 运行期的选表语义** —— 它只在给定 DT 数据上验算法。
   C17 的**设备侧**运行期语义已由真机全量轮覆盖（`results/20261005-224132`，T2.2 执行后 `adsp_read`=3250 = 该 ROM 表算出的原厂值）；
   若要**静态**核对，需反编译 `ddrc_v2_strategy_register`；
3. 基线**只有一份真机 DT**（C16 6.6.89）；跨 ROM 的 DT 差异由 `<EXTERNAL>/回归检查/corpora/` 覆盖，
   但那是取证工作区、**不随本测试携带** ⇒ 换 ROM 后若要广泛覆盖，需先跑 `fcc_verify_dtbo_tables.py` 重建语料。

> 改了 `log.sh` 的自检清单后**必须重跑**：`python3 dt_inject/gen_dt.py` 然后 `run_cases.py`（否则语料期望值与新自检不符）。
> 设计背景、"假绿"教训、13 例逐条清单与哨兵意义见 `dt_inject/README.md`。

---

## 3. 断言词汇表（`snap.sh` 输出的 key）

| key | 来源 | 说明 |
|---|---|---|
| `module_loaded` | `lsmod` | 0/1 |
| `param_target` | `/sys/module/uv2800/parameters/uv_target_mv` | 关机电压 |
| `param_adsp` | `.../uv_adsp_mv` | ADSP 目标（**v11 新参数**；旧版无 → `?`） |
| `param_resume` | `.../resume` | 0 = hook 生效；1 = 恢复模式 |
| `adsp_read` | `.../adsp_read`（先 `echo 1` 再读） | **电量计真实 term** |
| `vbat_uv` | `/sys/class/oplus_chg/battery/vbat_uv` | 实际关机电压 |
| `chip_soc` / `capacity` | 电量计原始 SOC / Android 显示 | bind 后应相等 |
| `bind_layers` | `/proc/self/mountinfo` | `chip_soc` 出现次数 |
| `skip` | `$BK/skip` 是否存在 | yes/no |
| `adsp_orig` | `$BK/adsp_orig.txt` | 出厂值（**本机 3250 / 新机 3060**） |
| `target_file` | `$BK/target_mv` | 用户设定值 |
| `count` | `deep_dischg_counts` | 深度放电计数 |
| `retry_proc` | `ps` | 残留 `adsp_retry` 数量（**v10 遗留；v11 已无 `adsp_retry`，该断言恒真**，保留只为兼容旧报告） |

**期望值公式**：`ADSP = V_s − max(0, FLOOR − V_s)`，**FLOOR = 3060**。

---

## 4. 判读与排查

| 现象 | 可能原因 |
|---|---|
| T1.2/T2.4 失败（`vbat_uv` 不跟随） | 内核 hook 处于放行状态（`uv_bypass=1`）/ `resume != 0` —— v11 的 `service.sh` 会检测到并统一复位（写 `resume=1`），若仍失败先看该复位有没有跑到 |
| T1.3/T6.x 失败（ADSP 值不对） | ADSP 派生公式没实现 / FLOOR 取值不符（用 `UV_FLOOR` 试另一套口径） |
| T4.1 失败但 T3.1 通过 | 越狱路径的 `uv_dev` 自动捕获没生效（看 `logs/T4.1.snap` 与设备 `uv2800.log`） |
| **T3.2 失败（软重启后 `vbat_uv`=2800 而非原厂）** | 先区分两种情况：**卸载/rmmod 后**读到 2800 是**驱动自身行为**（见 §2 T7 的"卸载后 `vbat_uv` 为什么不能断言"，模块无法控制、不断言）；**软重启（ksud）后**该值应保持原厂 —— 若此时仍 2800，才需要看 `logs/T3.2.snap` 与设备 `uv2800.log` |
| T5.1 失败 | skip 分支没有把 ADSP 拉回原厂 |
| T2.x 失败 | `action.sh` 的恢复流程有回归 |
| 大量用例 SKIP | 设备不可达 / 无 su / 软重启不可用 —— 先手工确认 `adb shell su -c id` |
| `T3/T5/T6.6/T7.2/T9.1/T9.2/T10.5` 全 SKIP | **正常**：标准启动路线默认不跑重启组，要跑加 `--with-reboot` |
| `T4.1/T4.2` SKIP | **正常**：越狱专属（标准启动没有 ghostlock 注入这条路径） |
| `T10.x` SKIP | **正常**：标准启动专属。整组 SKIP ⇒ 当前是越狱路线 |
| 启动即报「无法判定启动路线」 | 模块日志里两个标记都没有（例如刚删过 `/data/adb/uv2800_backup`）→ 用 `UV_ROUTE=standard\|late-load` 显式指定 |
| 日志出现「uv_dev 未捕获，主动触发 deep_dischg 入口」 | **多半正常**（T10.3 只记录不断言）：KSU 软重启 / 刚装完模块时，**驱动开机 vote 早已在真开机时发生过**，模块走设计内的主动捕获兜底。要验证「驱动开机 vote」这条路径，**必须在本模块已安装的前提下硬重启一次** —— 即 `--with-reboot` 跑 T10.5 |

**手工复现单个用例**：直接调设备侧脚本
```sh
adb shell "su -c 'sh /data/local/tmp/uvtest/snap.sh'"            # 看当前状态
adb shell "su -c 'sh /data/local/tmp/uvtest/apply.sh decouple 2800'"
adb shell "su -c 'sh /data/local/tmp/uvtest/apply.sh factory'"
```

---

## 5. 覆盖与不覆盖

**覆盖**：解耦/出厂两态、点执行、软重启、硬重启+越狱、状态切换、自定义关机电压、边界污染、
竞态/残留（T9）、**标准启动路线专属行为（T10）**。

**两条路线各覆盖什么**：

| | standard 标准启动 | late-load 越狱 |
|---|---|---|
| 功能面（T0/T1/T2/T6/T8） | ✅ 全跑 | ✅ 全跑 |
| 竞态面（T9.3） | ✅ | ✅ |
| 重启面（T3/T5/T6.6/T7.2/T9.1/T9.2） | 默认 SKIP（`--with-reboot` 可跑） | ✅ |
| 越狱注入路径（T4.x） | ❌ 不适用 | ✅ |
| 标准启动专属（T10.x） | ✅ | ❌ 不适用 |

**不覆盖（刻意排除）**：
- **放电到自动关机测 0% 落点** —— 每次数小时，属于长测，见 `文档/历史/REFACTOR-uv2800-v10.19.md` §2.4
- **跨版本真机**：**C15 / C16 / C17 共 5 款 ROM × 4 个内核**均有真机全量轮（最新一轮 C17.0.0.101/6.6.118 = `results/20261005-224132`，31/0/2）。
  **权威口径见 [兼容性总表.md](兼容性总表.md)**（含每格 PASS/FAIL/SKIP、空白格清单与"对外可宣称范围"）——
   **本文不再重复维护兼容性结论**，只讲怎么跑。
- **覆盖安装** —— 未做（会改变安装状态）；**卸载已覆盖**（T7.2）

---

## 6. 给子代理的约束

0. **被测版本是 v11**；改过源码先跑 `./build.sh`，否则测的是旧包
1. **只跑 `run.sh`**，不要手改设备文件（除排查外）
2. **不要插拔充电器** —— v10.19 起全场景零插拔是核心验收项，插拔会污染结论
3. 重启组会真的重启设备（软重启/硬重启+越狱），**跑之前确认用户没在用手机**；
   标准启动路线默认不跑重启组；`--with-reboot` 下 T10.5 会硬重启（不注入 ghostlock）
3.1 **不要在跑到一半时切路线**（换 init_boot 补丁 / 注入 ghostlock）—— 路线是启动时判定的，中途切换会让后半段的断言失去意义
4. 失败时**先看 `results/<ts>/logs/<case>.snap`**（设备原始快照）再下结论
5. 测试结束会自动恢复解耦态 2800；若中途中断，手工跑一次
   `apply.sh decouple 2800` 恢复
