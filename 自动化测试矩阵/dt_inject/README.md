# dt_inject —— uv_dt_orig() 失败注入语料与断言测试

> 2026-10-05 重建。针对 log.sh 中的 uv_dt_orig()（按厂商语义推算原厂电量计终止电压）。

## 为什么重建（v1 的"假绿"）

v1 的生成器（见 gen_dt_v1.py.bak）每个用例**只在**
strategy_ratio_range_high/strategy_temp_warm 下建一张表，
而标准调用 cnt=1758 cc=344 temp=300 解析出的是
region=3(strategy_ratio_range_mid) / index_t=2(strategy_temp_normal)。

→ 路径不存在 → **10 个用例里有 9 个得到同一条 FAIL 表自检 ERR empty**。
测试看起来"全部按预期失败(rc=1)"，实际上**根本没走到各自声称要测的检查** —— 这是假绿。

v1 另有两个问题：基线表是手造的非真实数据；缺"误杀哨兵"。

## v2 的设计

| 方面 | v2 做法 |
|---|---|
| **基线** | 直接复制**真机活 DT 语料** <EXTERNAL>/回归检查/corpora/PJZ110_16.0.5.701_C16a_dtb0/silicon_p_770/，完整 6 region × 4 temp 网格，基线值 = 真机实测 3250 |
| **缺陷注入点** | 统一注入到**标准调用命中的那张表** strategy_ratio_range_mid/strategy_temp_normal，保证用例真的走到目标检查 |
| **哨兵** | v0drop_ok：真实厂商**合法 v0 回落**表（行 0 基准 3100 → 行 1 3000），**必须通过** |
| **断言** | run_cases.py 逐例断言预期值/预期失败原因，不符即 FAIL 并非零退出 |

## 用法

    cd .
    python3 自动化测试矩阵/dt_inject/gen_dt.py             # 重建语料（会清空 dtgen/）
    python3 自动化测试矩阵/dt_inject/run_cases.py          # 跑全部并断言
    python3 自动化测试矩阵/dt_inject/run_cases.py valid rr4   # 只跑指定用例

    # 哨兵自测：把已删除的 v0_order 注回副本，确认哨兵能抓到回归
    python3 自动化测试矩阵/dt_inject/mk_v0order_variant.py
    UV_DT_LOG=/tmp/log_with_v0order.sh python3 自动化测试矩阵/dt_inject/run_cases.py v0drop_ok
    # 预期：v0drop_ok FAIL（说明哨兵有效）

退出码：0 = 全部符合预期；1 = 有用例未达预期。

## 用例清单（13 例）

标准调用：UV_T_BATT=silicon_p_770 UV_T_CNT=1758 UV_T_CC=344 UV_T_CALI=0 UV_T_TEMP=300

| 用例 | 注入 | 期望 |
|---|---|---|
| valid | 无（真机活 DT 原样） | 3250 |
| v0drop_ok | 真实厂商合法 v0 回落表 | **3060（必须通过）** |
| rr_missing | 删 oplus,ratio_range | 失败：ratio_range 项数=0 |
| rr4 | ratio_range 写成 4 项 | 失败：ratio_range 项数=4 |
| tr2 | temp_range 写成 2 项 | 失败：temp_range 项数=2 |
| f0base | 首行 f0 不等于 0 | 失败：ERR f0_base |
| f0order | 第 3 行 f0 小于第 2 行 | 失败：ERR f0_order |
| size_bad | 追加 1 字节（65B） | 失败：ERR size |
| rows9 | 9 行 | 失败：ERR rows |
| volt_hi | 末行 v1=60000 | 失败：ERR volt_range |
| oob_2600 | 选中行 v1=2600（在 2000~5000 内） | 失败：结果越界 |
| misparse12 | 真机 4x16B 转 4x12B=48B（绕过 size） | 失败：ERR volt_range |
| empty | 无 battery 子树 | 失败：未找到含 ddrc_strategy |

## 哨兵的意义

v0_order（"vbat0 列非降"）曾是 log.sh 的一条表自检，**误拒真实厂商表**：
厂商 min/low 表行 0 是 (f0=0, 高电压) 的**基准记录**，阶梯从行 1 重新起算，
行 1 的 v0 回落。按内容去重实测 81 张不同的表中 **9 张（11.1%）合法违反**。
该检查已于 2026-10-05 删除。

- v0drop_ok 保证它**不会被重新引入**；
- misparse12 保证删除它**没有打开安全缺口**（12 B/行 错位仍由 volt_range 拦下）。

注意 valid（真机表 v0 = 3000/3100/3200/3300 单调递增）**不能**起到哨兵作用 ——
所以 v0drop_ok 不可省。

## 说明

- 同目录下 t1.sh…t6.sh、probe.sh、recon*.sh、fix4.sh、ver.sh、fin.sh、clean.sh
  是更早会话的临时脚本，**已被 gen_dt.py + run_cases.py 取代**，保留仅供追溯。
- gen_dt_v1.py.bak 是重建前的生成器，保留用于对照"假绿"问题。