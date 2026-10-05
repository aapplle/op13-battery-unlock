# RE-E：实机 `battery_fcc` 三态跳变的根因（地址级 / 寄存器级取证）

- 取证日期：2026-10-05
- 实机：`<SERIAL>`，**PJZ110_16.0.5.701(CN01) / Android 16 / kernel 6.6.89-android15-8**
- 主证物：`<EXTERNAL>/厂商驱动与固件/versions/coloros16.0.5.701/oplus_chg_v2.ko`
  （**与实机版本一一对应**，9,693,776 B）
- 复核证物：`versions/coloros17.0.0.100/oplus_chg_v2.ko`（结论完全一致，结构体偏移差 `-0x30`）
- 手段：**只读**。反汇编 `/usr/lib/llvm-18/bin/llvm-objdump`；自写 BTF 解析器
  `逆向脚本与产物/逆向脚本/btf_dump.py`（本 ko 的 `.BTF` 是 **split BTF**，实测 base 串表长
  `0x261376`，据此才能解出字段名）；DTB 用 `dtc`；实机 `adb exec-out su -c "cat ..."`。
- **未对设备做任何写操作**（不改 sysfs、不装模块、不重启）。所有实机数值均为 `cat` 采样。

---

## 0. 一句话结论

> `/sys/class/oplus_chg/battery/battery_fcc` **不是电量计的 FCC**，而是 OPLUS 的**显示口径**：
>
> ```
> battery_fcc_sysfs = min( GAUGE_ITEM_FCC + GAUGE_ITEM_FCC_COEFF × GAUGE_ITEM_SOH / 100 ,
>                         oplus,batt_capacity_mah（DT 铭牌容量 5920）)
> ```
>
> 三态全部由这一条 printf 前的表达式产生，**没有"读 IC 失败 → 设计容量兜底"这条路径**
> （读失败的回退是 **2000** / **0**，见 §4.3）。③ 的 5920 是**上限钳位**，不是兜底。
> 它与模块的 term 电压解耦**只通过 A = `GAUGE_ITEM_FCC` 一个入口**相连；
> **"改 term → 学习态丢失 → 回落设计容量"这条链不成立**（学习的载体 QMAX 全程未变）。

---

## 1. `battery_fcc` 的 show 路径（**已证实**）

### 1.1 定位

| 符号 | 16.0.5.701（实机版本） | 17.0.0.100（复核） |
|---|---|---|
| `battery_fcc_show` | **0x42eb8** | 0x4ccec |
| `battery_rm_show` | 0x42f48 | 0x4ce78 |
| `battery_soh_show` | 0x42f88 | 0x4ceb8 |
| `design_capacity_show` | 0x44888 | 0x4e88c |
| `oplus_configfs_subscribe_gauge_topic` | 0x40de8 | 0x4ab5c |
| `oplus_configfs_gauge_update_work` | 0x403f0 | 0x4a0c4 |
| `oplus_gauge_get_batt_capacity_mah` | 0x167c40 | 0x194338 |
| `oplus_mms_gauge_update_fcc` | 0x174090 | 0x1a1040 |
| `oplus_chg_vg_get_batt_cap` | 0x1358c8 | 0x15ee70 |
| `oplus_bq27541_get_batt_fcc` | 0xc52a8 | 0xe10dc |
| `bq27541_get_battery_fcc` | 0xb8ad8 | 0xd4ff0 |
| `bq28z610_get_battery_qmax` | 0xc7d70 | 0xe3d74 |
| `oplus_mms_gauge_sili_term_volt_effect_check_work` | 0x18f668 | 0x1bd608 |

`dev_attr_battery_fcc` → `battery_fcc_show`；`dev_attr_design_capacity` → `design_capacity_show`。
`show(struct device *dev, ...)` 里 `ldr x?, [x0, #0x98]` = `dev_get_drvdata()`，得到的是
**`struct oplus_configfs_device`**（BTF id=368；本版 `gauge_topic` @0x60、`batt_*` @0x490…0x4ac）。

### 1.2 实机版本反汇编全文（16.0.5.701 `battery_fcc_show` @0x42eb8）

```asm
42ec8: ldr  x9, [x0, #0x98]        ; x9  = cfd
42ed0: ldr  w10, [x9, #0x4a0]      ; A' = cfd->batt_soh          (GAUGE_ITEM_SOH   = item 9)
42ed4: ldr  w8,  [x9, #0x494]      ; B' = cfd->batt_fcc          (GAUGE_ITEM_FCC   = item 7)
42ed8: sub  w11, w10, #0x1
42edc: cmp  w11, #0x63
42ee0: b.hi 0x42f1c                ; 若 (soh-1) > 99（无符号）→ 跳过补偿
42ee4: ldr  w11, [x9, #0x4a4]      ; C' = cfd->batt_fcc_coeff    (GAUGE_ITEM_FCC_COEFF = item 23)
42ee8: cbz  w11, 0x42f1c           ; 若 coeff == 0 → 跳过补偿
42eec: mul  w10, w11, w10          ; C' * SOH
42ef0: mov  w11, #0x851f
42ef8: movk w11, #0x51eb, lsl #16  ; ← 有符号除 100 的魔数
42efc: smull/asr#37/...            ; w10 = (C' * SOH) / 100
42f0c: add  w20, w10, w8           ; w20 = batt_fcc + (coeff * soh)/100
42f10: bl   oplus_gauge_get_batt_capacity_mah      ; w0 = D（见 §4）
42f14: cmp  w20, w0
42f18: csel w8, w20, w0, lt        ; ★ w8 = (w20 < w0) ? w20 : w0  == min(w20, w0)
42f1c: ...
42f2c: bl   sprintf(buf, "%d\n", w8)
```

**`csel ... lt` 的位级校验（不是靠 objdump 口头说明）**：`csel Wd,Wn,Wm,cond` 的编码是
`sf op S 11010100 Rm cond op2 Rn Rd`（`op2=00` 即 CSEL）。16.0.5.701 0x42f18 的机器码为
`1a80b288` → 逐位拆：`sf=0`(32bit)、`bits[28:21]=0b11010100`、`Rm=00000(x0)`、
`cond=1011(LT)`、`op2=00(CSEL)`、`Rn=10100(w20)`、`Rd=01000(w8)`。
⇒ 语义**确定为 min**，不是 max、不是"取设计容量"。

### 1.3 另外两条 show（同款公式族，**已证实**）

```asm
; battery_rm_show @0x42f48        （本版偏移 0x49c；C17 为 0x4cc）
42f68: ldr  w8, [x8, #0x49c]
42f6c: bic  w3, w8, w8, asr #31   ; = max(0, batt_rm)   ← 无任何补偿
42f70: bl   scnprintf

; battery_soh_show @0x42f88       （本版偏移 0x4a0 / 0x4a8）
42f90: ldr  w8, [x9, #0x4a0]      ; S  = batt_soh
42f94: sub w10, w8, #1 ; cmp #0x63 ; b.hi  → 跳过
42f9c: ldr  w9, [x9, #0x4a8]      ; C  = batt_soh_coeff
      ; cbz w9 → 跳过
      ; S + (C*S)/100
      ; cmp w8, #100 ; csel w8, w8, w9(100), lt   → = min(S + C*S/100, 100)
```

⇒ 三条公式同构：**`显示值 = min( 原值 + 系数×原值/100 , 上限 )`**，
上限对 SOH 是 `100`，对 **FCC 是设计容量**。这是 OPLUS 的"补偿不得越过 100%/铭牌"写法。

---

## 2. 缓存字段与刷新时机（**已证实**，这一条是"跳变"的关键）

`oplus_configfs_device` 里的 gauge 缓存**只有两个写入者**：

| 写入者 | 地址（16.0.5.701） | 写入项（item id）→ 偏移 |
|---|---|---|
| `oplus_configfs_subscribe_gauge_topic` | 0x40de8 | 0→0x490, 8→0x498, **7→0x494**, **10→0x49c**, **9→0x4a0**, 4→0x4ac, 19→0x4b8, **23→0x4a4**, **24→0x4a8**, 33→… |
| `oplus_configfs_gauge_update_work` | 0x403f0 | 0, 8, 7, 10, 9, 4, 33 —— **不含 23 / 24** |

`gauge_topic_item`（BTF 枚举，**已证实**）：
`SOC=0, GAUGE_VBAT=4, FCC=7, CC=8, SOH=9, RM=10, DEEP_SUPPORT=19,
FCC_COEFF=23, SOH_COEFF=24, RATIO_VALUE=30, RATIO_TRANGE=31, QMAX=32, CAR_C=33`

**推论（强）**：
- `batt_fcc`(item 7) / `batt_rm`(10) / `batt_soh`(9) 由 `..._gauge_update_work` **运行时刷新**；
- `batt_fcc_coeff`(23) / `batt_soh_coeff`(24) **只在 probe 时写一次**（update work 不碰），
  所以**同一次开机内 F 和 C 是常量**，能动的只有 `GAUGE_ITEM_FCC` 和 `GAUGE_ITEM_SOH`。

---

## 3. 三个状态的定义式（把 §1 的表达式拆开）

记
- `A = GAUGE_ITEM_FCC`（真·电量计满容量，运行时刷新）
- `S = GAUGE_ITEM_SOH`（运行时刷新）
- `F = GAUGE_ITEM_FCC_COEFF`（probe 后固定）
- `R = GAUGE_ITEM_RM`（运行时刷新）
- `D = DT \`oplus,batt_capacity_mah\`` = **5920**（见 §4）

则：
```
battery_fcc = (1 ≤ S ≤ 100 && F ≠ 0) ? min(A + F*S/100, D) : A
battery_rm  = max(0, R)
```

| 态 | 触发条件（**已证实**的判据） | 对应指令 |
|---|---|---|
| **① `fcc == rm`** | **补偿分支被短路**：`F == 0` **或** `S ∉ [1,100]`（含 S 瞬时读成 0）。此时 `battery_fcc = A`；而满充重锚（DOD=0）时电量计自身满足 `A == R`，故 `fcc == rm` | 0x42ee0 `b.hi` / 0x42ee8 `cbz` |
| **② `fcc > rm`** | 补偿生效，且 `A + F*S/100 < D` | 0x42eec–0x42f0c，`csel` 选走 w20 |
| **③ `fcc == 5920`（"设计容量"）** | 补偿生效，且 **`A + F*S/100 ≥ D = 5920`** → 被 `min` 钳到 5920 | 0x42f14/0x42f18，`csel` 选走 w0 |

### 3.1 实机数值分解（**数值精确匹配，但 A/F 拆分属推断**）

2026-10-05 实机采样（120 s 稳定）：

| 节点 | 值 | 含义 |
|---|---|---|
| `battery_fcc` | **5473** | 显示值（② 态） |
| `battery_rm` | **4406** | `max(0, GAUGE_ITEM_RM)` |
| `battery_soh` | **100** | 被上限 100 钳住 |
| `design_capacity` | **5920** | `oplus_gauge_get_batt_capacity_mah` |
| `chip_soc` | 100 | |
| `dmesg \| grep bs_update_data` | `rm=4406 fcc=4406 soc=100 full=1` | STRATEGY_BS 口径 |
| `battery_log_content`（列名见 `battery_log_head`） | `…batt_qmax=5487, batt_soh=97, batt_rm=4406, batt_fcc=4406…` | |
| `/sys/class/power_supply/battery/charge_full` / `charge_full_design` | 5920000 / 5920000 µAh | 都等于铭牌 |

代入：`4406 + F × 97 / 100 = 5473` ⇒ `F × 97 / 100 = 1067` ⇒ **F ∈ {1100, 1101}**（`1100*97/100 = 1067` 恰好整除）。
即 **`A=4406`（= 电量计满容量 = 满充时的 RM）、`S=97`、`F=1100`** 能**精确**复现 5473。

> **诚实标注**：`A=4406, F=1100` 这组解是**数值反解**，不是直接读出来的（`GAUGE_ITEM_FCC_COEFF` 无任何 sysfs 节点暴露）。
> 已证实的是**表达式本身**与 **D=5920**；未证实的是 F 的确切来源（§8 待补清单）。

---

## 4. `oplus_gauge_get_batt_capacity_mah()` = **设计容量（铭牌）**，不是电量计 FCC（**已证实**）

### 4.1 调用链

```
battery_fcc_show @0x42f10  ─┐
design_capacity_show @0x448a4 ─┴→ oplus_gauge_get_batt_capacity_mah(topic) @0x167c40
        → oplus_mms_get_drvdata(topic) → 取 gauge topic 的 sub-ic[0] / sub-ic[1]
        → oplus_chg_ic_debug_get_func(ic, 0x1b5 = 437 = OPLUS_IC_FUNC_GAUGE_GET_BATT_CAP)
        → blr → val；两个 sub-ic 求和
```
（重定位核对：16.0.5.701 `battery_fcc_show+0x58`→`oplus_gauge_get_batt_capacity_mah`，
`design_capacity_show+0x1c`→同一符号；C17 版同样。）

### 4.2 实现者 = 虚拟电量计，值来自 DT

```asm
; oplus_chg_vg_get_batt_cap @0x1358c8
ldr  x8, [x0, #0x8]      ; ic->dev
ldr  x8, [x8, #0x98]     ; drvdata
ldr  w8, [x8, #0x200]    ; ★ 直接返回 priv+0x200
str  w8, [x1]            ; *val = priv+0x200
```
`priv+0x200` 由 `oplus_virtual_gauge_probe` 通过 `of_property_read_variable_u32_array`
读入，属性名重定位指向 `.rodata.str1.1+0x78ce4` = **`"oplus,batt_capacity_mah"`**。

**DT 实证**（`dtc -I dtb -O dts work/dtbo_tables/16.0.5.701_dtb0_id0_rev0.dtb`）：

```dts
oplus,virtual_gauge {
    compatible = "oplus,virtual_gauge";
    oplus,gauge_ic = <0x4d>;                 /* oplus,adsp_gauge */
    oplus,gauge_ic_func_group = <0x4e>;
    oplus,batt_capacity_mah = <0x15ea>;      /* 5610 = 默认/兜底 */
    oplus,ic_type = <0x0d>;  oplus,ic_index = <0x00>;
    silicon_p_770 {                          /* ← 本机 battery_type */
        oplus,gauge_ic = <0x4d>;
        oplus,gauge_ic_func_group = <0x4e>;
        oplus,batt_capacity_mah = <0x1720>;  /* ★ 5920 = 一加13铭牌 */
        oplus,ic_type = <0x0d>;  oplus,ic_index = <0x00>;
    };
};
```

实机 `/sys/class/oplus_chg/battery/battery_type` = `silicon_p_770` ⇒ **D = 0x1720 = 5920**，
与 `design_capacity` 节点实测 5920 完全吻合。⇒ **D 的物理含义 = 电池铭牌设计容量**（常量）。

### 4.3 ★ 纠正 AUDIT §3b.2 的说法

`文档/AUDIT-uv2800-v11-独立审计.md` §3b.2 记「5920 的成因由用户确认为『电量计 fcc 读不到时的设计容量兜底』」。
**该归因不成立**：

| 情形 | `oplus_gauge_get_batt_capacity_mah` 的返回 |
|---|---|
| topic 为 NULL | **2000**（0x167c40 路径 `mov w?, #0x7d0`） |
| sub-ic 缺失 / 未实现 func 437 | **2000**（rc=-524 = -ENODEV） |
| sub-ic 数为 0 | **0**（`mov w?, wzr`） |
| **正常** | Σ func 437 = DT `oplus,batt_capacity_mah` |

⇒ **读失败会回 2000 或 0，永远不会"兜底成 5920"**。5920 只能由 `min()` 的**上限钳位**产生。

---

## 5. `GAUGE_ITEM_FCC`（= A）是怎么算出来的（**已证实**）

### 5.1 发布者

`oplus_mms_gauge_update_fcc` @0x174090：
```
w25 = IC func 0x1b1 (=433, OPLUS_IC_FUNC_GAUGE_GET_BATT_NUM)；取值失败则 w25 = 1
for each gauge sub-ic:  sum += IC func 0x197 (=407, OPLUS_IC_FUNC_GAUGE_GET_BATT_FCC)
factor = (sub_ic_num <= 1) ? w25 : 1
publish GAUGE_ITEM_FCC = factor * sum
```
（`ic_debug_get_func` + kCFI 类型哈希校验 `movk w17,#0x4194 / #0x4130` 为其贯穿写法。）

### 5.2 IC 侧实现（bq 家族分支）

```asm
oplus_bq27541_get_batt_fcc(ic, int *val) @0xc52a8
  priv = dev_get_drvdata(ic->dev)
  if (priv->[0x118] & 0x2) || (& 0x4) || (& 0x8) → *val = priv->[0x38]   ; ★ 走缓存
  else 走 I²C/ADSP 实读，成功后 str w?, [priv, #0x38] 回写缓存

bq27541_get_battery_fcc(chip) @0xb8ad8
  同上三个 flag 位判定（0x118 bits 1/2/3）
  非缓存路径：最多 3 次重试（usleep_range_state + bq27541_read_i2c）
  三次都失败 → 视 [0x118] bits 1/2/3 再决定回缓存 / 报错
```
⇒ **FCC 是"每读一次 IC"的；但有 `priv+0x118` bits1/2/3 的"用缓存"开关，
且缓存 `priv+0x38` 会被成功读刷新。** 这解释了小范围内 FCC 的台阶式变化。

### 5.3 本机是哪种电量计（重要限定）

- DT：`oplus,adsp_gauge { oplus,ic_type = <0x0c>; }`（`oplus,gauge_ic = <0x4d>` 指向它）；
  `oplus,mms_gauge` → `oplus,gauge_ic = <0x4c>` = `oplus,virtual_gauge`。
- dmesg 实机：`OPLUS_CHG[ADSP]([handle_bcc_read_buffer][708]): ----dod0_1[171], dod0_2[187],
  qmax_1[2747], qmax_2[2740], … voltage_cell1[4447], … soc_ext_1[981918], soc_ext_2[980922]`
  ⇒ **本机走 ADSP/SILI 算法电量计**（`OPLUS_SILI` / `nfg8011b` 一族符号）。
- 因此 §5.2 的 `bq27541` 是**同一 .ko 内的 bq 家族分支**（历史报告称"bq28z610"即指此）；
  本机上的 func 407 由 ADSP 电量计提供。**对三态结论无影响**（三态只依赖 A 的数值与 §2 的缓存）。
- `gauge_type` 节点实测 **0**，dmesg 反复 `can't get gauge type, rc=-524` ⇒
  RE-B §9 的 `gauge_type==1` SOH 补偿分支在本机**不生效**，`oplus_gauge_get_ratio_value`
  的除数仍是 `cc`（本次 344）。

---

## 6. 与模块"解耦（term 电压）"的关系（机制链）

### 6.1 模块写的是哪一处

模块 kprobe 挂在 `oplus_fg_set_deep_term_volt` / `oplus_fg_get_deep_term_volt`
（见 `内核源码/uv2800.c`，`kp_term_set` / `kp_term_get` / `kp_term_entry`）。
实机 `/sys/module/uv2800/parameters/`：`adsp_read=2540, uv_adsp_mv=2540, uv_target_mv=2800`；
dmesg：`OPLUS_CHG[ADSP](oplus_fg_set_deep_term_volt): rc=0, volt = 2540`。

DT 的 gauge 功能组确实含该 op（`/tmp/active.dts` 行 4197，`oplus,gauge_groups/functions` 列表：
`…0x1c8 0x1ce 0x1cc 0x1d9…`，另含 0x197(FCC)/0x198(CC)/0x199(RM)/0x19a(SOH)/0x1ee(dec_cv_soh)）。
> ⚠️ **版本口径提醒**：C17.0.0.100 的 BTF 枚举把 `SET_DEEP_TERM_VOLT` 记为 **456**、`GET_DEEP_TERM_VOLT` 记为 **462(=0x1ce)**，
> 与"op 0x1ce = set_deep_term_volt"的说法相反。**引用 op 号前必须先用设备版本 ko 的枚举核对**（本机 16.0.5.701）。

### 6.2 驱动侧静态铁证：驱动**假定** term 会改变电量计模型

`oplus_mms_gauge_sili_term_volt_effect_check_work` @0x18f668（**已证实**）：
```asm
18f6e8: mov  w1, #0x1d1            ; 465 = OPLUS_IC_FUNC_GAUGE_GET_SILI_SIMULATE_TERM_VOLT
        blr  ...                   ; 读回"模拟终止电压"
18f738: ldr  w1, [x19, #0x137c]    ; 期望值（驱动下发的 term）
18f73c: ldr  w8, [sp, #0x4]        ; 实际读回
18f740: subs w8, w1, w8
18f744: cneg w8, w8, mi            ; |期望 - 读回|
18f748: cmp  w8, #0x13             ; ★ > 19 mV 判为"未生效"→ 失败/重试路径
18f74c: b.gt 0x18f78c
```
配套字符串：`OPLUS_CHG[OPLUS_SILI]: expect term voltage=%d, simulate volt=%d`、
`… deep term voltage update success, current_volt: %d, term_voltage: %d`、
`… volt_mv[%d], reg_term_volt[%d], retry_count[%d] failed!`、
`OPLUS_CHG[NFG8011B]: set sys_term_voltage fail`；
以及 `single_dischg_term_volt / multiple_dischg_term_volt / cc_term_volt /
below_firmware_term_volt / cc_term_volt_ref / term_vol_maximum / term_volt_ok` 等参数名。
`nfg8011b_set_term_volt` @0x103790 是"写寄存器 + 读回比对 + 最多 3 次重试"的写-校验实现。

### 6.3 机制链（**结论**）

```
模块 kprobe 改 deep_term_volt（ADSP 里保存的 Termination Voltage）
   ↓（固件侧：SILI/Impedance-Track 模型的空电点下移）
电量计"满 ↔ 空"的可用容量窗口变大
   ↓（满充重锚：DOD 归零 / 满电状态切换时才重算）
GAUGE_ITEM_FCC（= A）上台阶      ← ★ 唯一被 term 影响的量
   ↓ battery_fcc_show
min(A + F·S/100, 5920)  的取值跨过 5920 → 显示从 ② 跳到 ③
```

**关键否定结论**：
1. **term 与 F(`FCC_COEFF`)、S(`SOH`)、D(铭牌 5920) 全都无关** ⇒ 改 term 只会移动 A。
2. **不存在"改 term → 学习态丢失 → 回落设计容量"这条链**。
   - ③ 的 5920 是**上限钳位**（`csel lt`），A 越大越容易触发，**恰恰是"学得更大"的表现**，不是"学丢了"。
   - 学习的载体是 **QMAX**，本机 dmesg 实测 `qmax_1[2747] qmax_2[2740]`，与历史章节记录
     （chapter24/25/29/35：`qmax 2747 不变`）一致 ⇒ **QMAX 未被打回**。
3. **真正会"丢学习态"的是另一条路**（与本次三态无关，但要说清以免混淆）：
   `term > vbat`（写了一个高于当前电压的终止电压）会让电量计判定"已放空" → 强制 **DOD=100%**
   并重算 FCC（`archive_work/chapter23`：4388 → 2492，且回写原值 + 重启**不自愈**），
   必须靠一次完整充电（DOD 重锚为 0）恢复。**这是误操作风险，不是 2540/2800 正常工作点的问题。**

---

## 7. 对续航 / 解容效果的影响评估

### 7.1 `battery_fcc` 是显示口径，不是执行口径（**已证实**）

- **关机/截止**：由 STRATEGY_BS 的 `rm/fcc/soc` 与 `vbat_uv`（模块 hook `uv_get` → `uv_target_mv=2800`）决定，
  `battery_fcc_show` 不参与任何 vote（它是 `dev_attr` 只读属性）。
- **UI 百分比**：Android 侧走 `/sys/class/power_supply/battery/capacity`（实机 =100）与
  `smooth_soc/uisoc`，不是 `battery_fcc/rm`。
- ⇒ **三态跳变不改变实际截止电压、不改变真实放电容量**。

### 7.2 但有两条真实影响

1. **第三方 App 读数会跳**：`battery_fcc` 可能在 `A`（态①）、`A+F·S/100`（态②）、`5920`（态③）
   之间跳，而同一时刻 `battery_rm` 是 `R`。用户看到的"fcc 等于 rm / 大于 rm / 变成设计容量"**全部是这一条 stdio 的产物**。
2. **SOH 显示被同一机制污染**：`battery_soh = min(S + SOH_COEFF*S/100, 100)`。
   历史章节里"soh 87→100"（`archive_work/chapter25`）**很可能是显示补偿而非电量计学习结果**
   —— chapter29/35 同时记录 `qmax/soh 不变`，两处矛盾由此得到统一解释。

### 7.3 建议（模块侧）

- **不需要、也不应该**由模块去"锁定/忽略" `battery_fcc`：它是纯显示节点，
  锁它既无收益，又要往内核塞额外 hook（增加 kCFI/版本适配风险）。
- **验证解容效果时不要用 `battery_fcc`**。改用（原 `PROJECT-vbat_uv-2800.md` 已由并行会话重命名为 `文档/PROJECT-v11.md`，此处给出地址级理由）：
  - `dmesg | grep bs_update_data` 的 `fcc`（STRATEGY_BS 口径）；
  - `/sys/class/oplus_chg/battery/battery_log_content`（列名见 `battery_log_head`）里的
    `batt_qmax / batt_soh / batt_rm / batt_fcc` —— 这是**驱动自身缓存值**，不含 §1 的显示补偿；
  - 0% 落点 + 关机电压（真正的效果指标）。
- **上游文档需要一笔更正**：`文档/PROJECT-v11.md:333` 现写
  「**不要用 `battery_fcc` 验证效果**。该节点**查询失败时会回退到设计容量**（本机 5920）」——
  **结论（别用它验证）正确，但机制写错了**。本文 §1/§4 已证明：
  (a) 该节点**不**在每次读时实查 IC，读的是 `oplus_configfs_device` 的缓存，只有
      `oplus_configfs_gauge_update_work` 会刷新它；
  (b) 5920 来自 `min()` 的**上限钳位**（DT 铭牌常量 `oplus,batt_capacity_mah`），
      **不是查询失败的兜底**（失败回退是 **2000 / 0**）。
  建议把该行理由改为：「它带 SOH 补偿、且被 DT 铭牌容量钳位，不是电量计真实 fcc」。

---

## 8. 可验证判据（全部只读）

| # | 判据 | 观测方式 | 预期 |
|---|---|---|---|
| V1 | 三态表达式 | `cat battery_fcc / battery_rm / battery_soh / design_capacity` | 恒满足 `battery_fcc ≤ design_capacity` 且 `battery_fcc ≥ battery_rm`（当 S 有效、F>0） |
| V2 | ③ 是钳位 | 找任一时刻 `battery_fcc == design_capacity`，同刻 `dmesg bs_update_data` 的 fcc 明显大于 `battery_rm` | 若 `A + F*S/100 ≥ 5920`，节点恒 = 5920，与 rm 无关 |
| V3 | ① 的成因 | 在**浅充放/ADSP 繁忙**（`dmesg` 出现 `get gauge type, rc=-524` 这类 ENODEV）时高频轮询 `battery_soh` | 若 `battery_soh` 瞬时为 0/负数，同刻 `battery_fcc` 应回落到 `= battery_rm`（态①） |
| V4 | F 固定 | 同一次开机内，`battery_fcc - battery_rm` 在 S 不变时应为常数 | 本机 5473-4406 = 1067（= F*97/100） |
| V5 | 铭牌常量 | `cat design_capacity` 与 DT `silicon_p_770/oplus,batt_capacity_mah` | 恒等于 5920（=`0x1720`） |
| V6 | 与 term 解耦 | 改 `uv_adsp_mv` 后等一次满充重锚，看 `battery_fcc` 是否只在**台阶式**跳变 | 若 A 变大且越过 `5920 - F*S/100`，显示转 ③；否则仍 ② |
| V7 | 学习未丢 | `dmesg | grep handle_bcc_read_buffer` 的 `qmax_1/qmax_2` | 改 term 前后不变（本机 2747/2740） |

---

## 9. 已证实 / 推测 分栏

### 已证实（有地址或实测）
1. `battery_fcc_show` 的指令级语义 = `min(batt_fcc + batt_fcc_coeff*batt_soh/100, oplus_gauge_get_batt_capacity_mah())`
   （**CSEL 位级解码** + 16.0.5.701/C17.0.0.100 双版本一致）。
2. 三个输入字段的 item id 与结构体偏移：FCC=item7@0x494、SOH=item9@0x4a0、FCC_COEFF=item23@0x4a4（16.0.5.701）。
3. 缓存刷新者：`subscribe_gauge_topic`（含 23/24，probe 一次）与 `gauge_update_work`（不含 23/24）。
4. `oplus_gauge_get_batt_capacity_mah` = `OPLUS_IC_FUNC_GAUGE_GET_BATT_CAP(437)`，
   由虚拟电量计读 DT `oplus,batt_capacity_mah`；本机 = `0x1720 = 5920`；
   失败回退为 2000/0，**不存在"设计容量兜底"**。
5. `battery_rm_show = max(0, GAUGE_ITEM_RM)`（无补偿）；
   `battery_soh_show = min(S + SOH_COEFF*S/100, 100)`。
6. `GAUGE_ITEM_FCC = Σ IC func 407 × num(func 433)`；bq 家族实现为"flag 位决定用缓存 `priv+0x38` 或实读"。
7. 驱动有 `..._sili_term_volt_effect_check_work`，读回模拟 term 电压并做 **|Δ| ≤ 19 mV** 判定。
8. 实机数值：fcc=5473 / rm=4406 / soh=100 / design=5920 / chip_soc=100；
   `battery_log_content` 的 batt_qmax=5487 / batt_soh=97 / batt_fcc=4406；
   dmesg `bs_update_data rm=4406 fcc=4406 soc=100 full=1`；ADSP `qmax_1[2747] qmax_2[2740]`。

### 推测（未直接证据，已标注依据）
1. **`F = GAUGE_ITEM_FCC_COEFF ∈ {1100,1101}`、`A = 4406`、`S = 97`**
   —— 数值反解精确匹配（4406+1100*97/100 = 5473），但无节点可直接读出。
   *注：`battery_soh` 实测 100 要求 `SOH_COEFF ≥ 4`；`battery_log_head` 的 batt_soh=97 与
   `GAUGE_ITEM_SOH` 是否同源，也属推断。*
2. **态① 的触发是"`GAUGE_ITEM_SOH` 瞬时越界（=0）"** —— 由 §1.2 的两个短路分支直接推出，
   但 120 s 满充稳态采样中未捕获到该瞬态（满充时不会发生）。
3. **term 下调必然抬高 A** —— 有大量历史实测（chapter24/29/32/35/37/38）与 §6.2 的驱动侧校验逻辑支撑，
   但**电量计固件内部无法静态分析**，属"实测归纳 + 驱动侧旁证"，不是寄存器级证明。
4. `GAUGE_ITEM_FCC_COEFF` 的**生产来源**（哪个函数 publish item 23/24）本次**未定位**；
   `oplus_mms_gauge_update_item` @ `.rodata+0x1e3d8` 不是简单的 {id, name, func} 表，未解出。

### 待补清单（下一轮）
- [ ] 定位 `GAUGE_ITEM_FCC_COEFF` / `SOH_COEFF` 的 publish 点（决定 F 是常量还是可变量 → 决定态①是"每台都可能有"还是"仅异常时"）。
- [ ] 在**放电中**（非满充）跑 V3 的高频采样，直接抓到态①的瞬态与对应的 `battery_soh` 读数。
- [ ] 用设备版本 ko 重新核对 `oplus_chg_ic_func` 枚举里 `SET/GET_DEEP_TERM_VOLT` 的真正编号（消除 op 0x1ce 的口径歧义）。

---

## 10. 证据索引（文件 / 命令）

| 结论 | 出处 |
|---|---|
| show 函数反汇编 | `versions/coloros16.0.5.701/oplus_chg_v2.ko` @0x42eb8 / 0x42f48 / 0x42f88 / 0x44888 |
| 结构体字段名 | `逆向脚本与产物/逆向脚本/btf_dump.py`（split BTF，base_str_len=0x261376）→ `oplus_configfs_device` id=368 |
| 缓存映射 | `oplus_configfs_subscribe_gauge_topic` @0x40de8；`oplus_configfs_gauge_update_work` @0x403f0 |
| 设计容量 | `oplus_gauge_get_batt_capacity_mah` @0x167c40；`oplus_chg_vg_get_batt_cap` @0x1358c8；`oplus_virtual_gauge_probe` |
| DT 铭牌 | `dtc -I dtb -O dts work/dtbo_tables/16.0.5.701_dtb0_id0_rev0.dtb` → `silicon_p_770/oplus,batt_capacity_mah = <0x1720>` |
| FCC 发布 | `oplus_mms_gauge_update_fcc` @0x174090；`oplus_bq27541_get_batt_fcc` @0xc52a8；`bq27541_get_battery_fcc` @0xb8ad8 |
| term 效果校验 | `oplus_mms_gauge_sili_term_volt_effect_check_work` @0x18f668（`cmp w8,#0x13`）；`nfg8011b_set_term_volt` @0x103790 |
| 实机采样 | `adb -s <SERIAL> exec-out su -c "cat /sys/class/oplus_chg/battery/{battery_fcc,battery_rm,battery_soh,design_capacity,chip_soc,gauge_type,battery_type,battery_log_content,battery_log_head}"` |
| 实机 dmesg | `adb -s <SERIAL> shell 'su -c "dmesg | grep -E 'bs_update_data|handle_bcc_read_buffer|gauge type|deep_term'"'` |
