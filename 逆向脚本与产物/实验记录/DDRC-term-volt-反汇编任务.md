# 任务：反汇编定位「电量计深度终止电压」的驱动计算路径

生成：2026-10-05（审计者）· 目的：把"驱动到底怎么算出终止电压"钉死，解释 3250 与 3350 的差异

## 1. 要回答的问题

模块（uv2800）在用户态实现了一个"原厂终止电压"的推算规则：
`deep_spec,term_coeff` + `deep_dischg_counts=1758`，取「计数阈值 ≤ counts 的最后一条」→ 本 ROM 得 **3350**。

但**驱动实际发布的值是 3250**（模块 hook 读到并采纳的真值）。同一台机、同一时刻：

| 来源 | 值 |
|---|---|
| 驱动实发（模块 hook `adsp_read` 读到，首次安装时 >FLOOR 3060 被采纳） | **3250** |
| 模块 DT 走查（term_coeff + counts） | **3350** |

怀疑：**模块查错了表**。驱动侧存在另一套表 `ddrc_strategy`（见 §3），其中 `(300, 3200, **3250**, 2)` 这一行的 `v_hi` 正好是 3250。

**需要确认**：
1. 驱动算「电量计深度终止电压」的**完整路径**（函数链 + 表 + 输入）。
2. `ddrc_strategy` 表怎么选行：**ratio** 与 **温度** 分别如何参与？表中第 1 字段（阈值）比较的对象是什么？
3. 4 元组 `(阈值, v_lo, v_hi, idx)` 里，**哪个字段**最终成为电量计终止电压？
4. 给定当前状态（电池温度 **35.6 °C**、`deep_dischg_counts=1758`、SOH=100、cycle_count=344），按驱动算法应得多少？**能否复现 3250**？
5. `deep_spec,term_coeff` 这张表**到底谁在用、用来干什么**（是否只用于别的用途，例如 `get_three_level_term_volt`）？

## 2. 已知事实（实测）

- 设备：OnePlus 13 (PJZ110)，ROM `PJZ110_16.0.5.701(CN01)`，内核 `6.6.89-android15-8-g7e1f3c083cc6-abogki467167594-4k`
- 驱动：`<EXTERNAL>/厂商驱动与固件/versions/coloros16.0.5.701/oplus_chg_v2.ko`
  （md5 `c6fedbc820fac7c6b9c3593b4020b215`，9.7 MB，**符号表完整，静态函数有名字**）
- 电量计 IC：`silicon_p_770`（battery_type）。相关 sysfs 实测：
  - `deep_dischg_counts` = 1758
  - `deep_dischg_ratio_thr` = 30
  - `/sys/class/oplus_chg/battery/get_three_level_term_volt` = `first=0,second=0,third=0`（全 0）
- 模块 hook 的是驱动导出的 gauge 存取函数（`oplus_chg_8350_gauge_get_func` id 0x1ce/0x1c8 的间接路径），
  读的是**电量计 IC 的深度终止电压**。
- **同一份 DT（`ddrc_strategy` 全部逐项相同）**：C15.0.0.861(6.6.66, 驱动 `715531c3`) 上模块记录 3350；
  C16.0.5.701(6.6.89, `c6fedbc8`) 上读到 3250 ⇒ 差异可能在**驱动版本**或**运行时输入**（温度/ratio）。
- 温度分档边界：DT `oplus,temp_range = [-50, 100, 350]`（0.1 °C）⇒ **-5.0 / 10.0 / 35.0 °C**。
  当前电池温度 35.6 °C ⇒ **warm** 档；本 ROM `warm` 与 `normal` 各档**逐项相同**。

## 3. DT 参考数据

## DT 参考数据（真机 C16.0.5.701 / 6.6.89 实拉，4 元组 = (阈值, v_lo, v_hi, idx)）

oplus,ratio_range = [20, 30, 50, 70, 90]
oplus,temp_range  = [4294967246, 100, 350]   # 0.1°C → -5.0 / 10.0 / 35.0

### strategy_ratio_range_min
  cold    (6 行) (0, 2800, 3000, 0)  (400, 2900, 3050, 1)  (800, 3000, 3060, 2)  (1200, 3100, 3150, 3)  (1600, 3200, 3250, 4)  (2000, 3300, 3350, 5)
  cool    (6 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (500, 3000, 3060, 2)  (1000, 3100, 3150, 3)  (1500, 3200, 3250, 4)  (2000, 3300, 3350, 5)
  normal  (5 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (500, 3100, 3150, 2)  (1000, 3200, 3250, 3)  (1500, 3300, 3350, 4)
  warm    (5 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (500, 3100, 3150, 2)  (1000, 3200, 3250, 3)  (1500, 3300, 3350, 4)

### strategy_ratio_range_low
  cold    (6 行) (0, 2800, 3000, 0)  (300, 2900, 3050, 1)  (600, 3000, 3060, 2)  (900, 3100, 3150, 3)  (1200, 3200, 3250, 4)  (1600, 3300, 3350, 5)
  cool    (6 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (400, 3000, 3060, 2)  (800, 3100, 3150, 3)  (1200, 3200, 3250, 4)  (1600, 3300, 3350, 5)
  normal  (5 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (400, 3100, 3150, 2)  (800, 3200, 3250, 3)  (1200, 3300, 3350, 4)
  warm    (5 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (400, 3100, 3150, 2)  (800, 3200, 3250, 3)  (1200, 3300, 3350, 4)

### strategy_ratio_range_mid_low
  cold    (6 行) (0, 2800, 3000, 0)  (200, 2900, 3050, 1)  (400, 3000, 3060, 2)  (600, 3100, 3150, 3)  (900, 3200, 3250, 4)  (1200, 3300, 3350, 5)
  cool    (6 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (300, 3000, 3060, 2)  (600, 3100, 3150, 3)  (900, 3200, 3250, 4)  (1200, 3300, 3350, 5)
  normal  (5 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (300, 3100, 3150, 2)  (600, 3200, 3250, 3)  (900, 3300, 3350, 4)
  warm    (5 行) (0, 3000, 3060, 0)  (15, 3000, 3060, 1)  (300, 3100, 3150, 2)  (600, 3200, 3250, 3)  (900, 3300, 3350, 4)

### strategy_ratio_range_mid
  cold    (6 行) (0, 2800, 3000, 0)  (100, 2900, 3050, 1)  (300, 3000, 3060, 2)  (500, 3100, 3150, 3)  (700, 3200, 3250, 4)  (900, 3300, 3350, 5)
  cool    (5 行) (0, 3000, 3060, 0)  (100, 3000, 3060, 1)  (300, 3100, 3150, 2)  (600, 3200, 3250, 3)  (900, 3300, 3350, 4)
  normal  (4 行) (0, 3000, 3060, 0)  (100, 3100, 3150, 1)  (300, 3200, 3250, 2)  (600, 3300, 3350, 3)
  warm    (4 行) (0, 3000, 3060, 0)  (100, 3100, 3150, 1)  (300, 3200, 3250, 2)  (600, 3300, 3350, 3)

### strategy_ratio_range_mid_high
  cold    (6 行) (0, 2800, 3000, 0)  (50, 2900, 3050, 1)  (100, 3000, 3060, 2)  (150, 3100, 3150, 3)  (300, 3200, 3250, 4)  (500, 3300, 3350, 5)
  cool    (5 行) (0, 3000, 3060, 0)  (50, 3000, 3060, 1)  (100, 3100, 3150, 2)  (150, 3200, 3250, 3)  (300, 3300, 3350, 4)
  normal  (4 行) (0, 3000, 3060, 0)  (50, 3100, 3150, 1)  (100, 3200, 3250, 2)  (150, 3300, 3350, 3)
  warm    (4 行) (0, 3000, 3060, 0)  (50, 3100, 3150, 1)  (100, 3200, 3250, 2)  (150, 3300, 3350, 3)

### strategy_ratio_range_high
  cold    (6 行) (0, 2800, 3000, 0)  (50, 2900, 3050, 1)  (100, 3000, 3060, 2)  (150, 3100, 3150, 3)  (300, 3200, 3250, 4)  (500, 3300, 3350, 5)
  cool    (5 行) (0, 3000, 3060, 0)  (50, 3000, 3060, 1)  (100, 3100, 3150, 2)  (150, 3200, 3250, 3)  (300, 3300, 3350, 4)
  normal  (4 行) (0, 3000, 3060, 0)  (50, 3100, 3150, 1)  (100, 3200, 3250, 2)  (150, 3300, 3350, 3)
  warm    (4 行) (0, 3000, 3060, 0)  (50, 3100, 3150, 1)  (100, 3200, 3250, 2)  (150, 3300, 3350, 3)


## 4. 关键符号

DDRC 策略（解析并持有这些表）：
```
0x19b7c4  ddrc_strategy_alloc              (0x8)
0x19b7d0  ddrc_strategy_alloc_by_node     (0x7ac)   ← 解析 DT 表，重点
0x19bf80  ddrc_strategy_release           (0xd0)
0x19c054  ddrc_strategy_init              (0x484)
0x19c4dc  ddrc_strategy_get_data          (0x98)    ← 取值入口，重点
```
SILI（算法侧终止电压）：
```
0x0c8554  oplus_gauge_get_sili_simulate_term_volt   (0x70)
0x0c85c8  oplus_gauge_get_sili_ic_alg_term_volt     (0x70)
0x0c8720  oplus_gauge_set_sili_ic_alg_term_volt     (0x70)
0x18e760  oplus_mms_gauge_get_sili_ic_alg_term_volt (0x260)
0x3f89c   get_three_level_term_volt_show            (0x84)
```
深度终止电压（模块 hook 的正是这一层）：
```
oplus_get_deep_term_volt                (0x204)
oplus_set_deep_term_volt                (0x5d0)
oplus_chg_vg_get_batt_deep_term_volt    (0x170)
oplus_chg_vg_set_batt_deep_term_volt    (0x1b0)
```
DT 解析 / 错误串（定位解析点）：
```
of_property_count_elems_of_size / of_property_read_variable_u32_array / of_property_read_string
"ddrc_strategy not found" / "Count ratio_temp_range failed" / "Count temp_range failed"
"Count deep spec term_coeff failed" / "ddrc_tbatt get oplus,temp_range property error"
"oplus,ddrc_strategy_name reading failed" / "can't get ddrc_curve"
"OPLUS_CHG[STRATEGY_DDRC]" / "OPLUS_CHG[OPLUS_SILI]"
属性名串: ddrc_strategy / ddrc_curve / deep_spec / term_coeff / temp_range / temp_type
          strategy_temp_cold / strategy_temp_normal / ratio_range
```

## 5. 工具（本机已装）

| 用途 | 命令 |
|---|---|
| aarch64 反汇编 + 符号 | `/usr/lib/llvm-18/bin/llvm-objdump`（binutils 的 `objdump` **不支持** aarch64） |
| 交互反汇编 | `radare2` / `r2` |
| 反编译 | Ghidra：`<HOME>/reverse/bin/ghidraRun`（无头 `analyzeHeadless`） |
| Python | `<HOME>/reverse/venv/bin/python3`（已装 **capstone 5.0.7** + **pyelftools**） |

```sh
OBJ=/usr/lib/llvm-18/bin/llvm-objdump
$OBJ -t drv.ko | grep <name>
$OBJ -d --start-address=0x19b7d0 --stop-address=0x19bf7c drv.ko
$OBJ -s -j .rodata drv.ko | grep -i ddrc
```
**符号表完整 ⇒ 优先按符号定位**，再用 `adrp/add` 交叉引用字符串地址确认。

## 6. 六份驱动（跨版本比对用）

| `.../versions/` 下的目录 | 来源 ROM | 内核 | md5 |
|---|---|---|---|
| `coloros16.0.5.701/oplus_chg_v2.ko` | C16.0.5.701 | 6.6.89 | `c6fedbc820fac7c6b9c3593b4020b215` |
| `coloros15.0.0.861/oplus_chg_v2.ko` | C15.0.0.861 | 6.6.66 | `715531c3bbb9db097c803efd62c10fce` |
| `coloros15.0.0.821/oplus_chg_v2.ko` | C15.0.0.821 | 6.6.30 | `7aaf68e138b01bd85d9c6a412bda2de6` |
| `coloros15.0.0.126/oplus_chg_v2.ko` | C15.0.0.126 | 6.6.30 | `2895f82d6b81478151461bbf91ed5dbe` |
| `coloros16.0.0.212/oplus_chg_v2.ko` | C16.0.0.212 | vermagic 6.6.89 | `c75d23e66a2610fdeab39e72c4cf143b` |
| `coloros17.0.0.100/oplus_chg_v2.ko` | C17.0.0.100 | vermagic 6.6.118 | `891cb06b6b9c41d088630a9dcf917a2c` |

## 7. 产出要求

写一份 Markdown 结论文件，包含：
- 函数链（地址 + 名字 + 作用）
- **选择算法伪代码**（阈值和谁比、ratio 从哪来、温度从哪来、v_lo/v_hi 谁出局）
- 对 §1 的 5 个问题逐条回答，**明确区分"已证实"与"推测"**
- 关键反汇编片段（带地址），便于复核
