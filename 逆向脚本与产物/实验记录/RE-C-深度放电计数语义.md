# RE-C：OPlus 驱动 "深度放电计数"（deep_dischg_counts）语义逆向

- 目标文件：`<EXTERNAL>/厂商驱动与固件/versions/coloros16.0.5.701/oplus_chg_v2.ko`
  （md5 `c6fedbc820fac7c6b9c3593b4020b215`，aarch64，内核 6.6.89）
- 设备：OnePlus 13 (PJZ110)，ROM C16.0.5.701，`CONFIG_HZ=250`
- 方法：`llvm-objdump -d -r`（读重定位解析 bl/adrp）+ 模块 `.BTF` 与真机 `/sys/kernel/btf/vmlinux` 拼接后的 BTF 类型还原 +
  `dtbo.img` 内 `deep_spec` 实际 DT 值 + 真机只读 sysfs 交叉验证
- 全文中「实测」= 反汇编/BTF/DT/sysfs 直接可见；「推测」= 推断

---

## 0. 一句话结论

`/sys/devices/virtual/oplus_chg/common/deep_dischg_counts` = `oplus_mms_gauge.deep_dischg_spec.counts`
（`chip+0xFD4`）。**它不是"循环次数"，也不是"深度放电事件次数"，而是一个内核维护的"深度放电当量累积分值"**：
每满足一次深度放电条件就先把采样计数器 +1，累计到 `ctime` 次后，**把温度相关的步进值 step（10 / 12 / 15 / 20）加到计数上**（不是 +1）。
数值持久化在电量计（FG / ADSP 侧）里，由内核在初始化时读回。

---

## 1. 谁维护它？——内核维护累加逻辑，FG/ADSP 只做持久化存储

### 1.1 结构体归属（BTF 实证）

模块 `.BTF` 是 **split BTF**（基础 BTF = 设备上 `/sys/kernel/btf/vmlinux`，`str_len=0x25DC7D`，
模块字符串起始偏移 `0x25DC7C`）。还原出：

```
struct deep_dischg_spec {          // L1477, size 2576 = 0xA10
  +0x00 u8  support;
  +0x04 s32 counts;               // ← deep_dischg_count（主电量计）
  +0x08 s32 sub_counts;           // ← sub_deep_dischg_count（副电量计）
  +0x0c s32 cc;                   // ← 库仑计 GAUGE_ITEM_CC（或 dec_cv_soh），用于算 ratio
  +0x10 s32 sub_cc;
  +0x14 s32 ratio;
  +0x18 s32 sub_ratio;
  +0x1c u8  sili_err;
  +0x20 struct ddb_temp_range ddbc_tbatt;    // 24B: {range; index_n(+8); index_p(+0xc); temp_type(+0x10)}
  +0x38 struct ddb_temp_range ddbc_tdefault;
  +0x50 struct ddb_temp_range ddrc_tbatt;
  +0x68 struct ddb_temp_range ddrc_tdefault;
  +0x80 struct ddb_curves batt_curves[20];   // 每个 76B
  +0x670 struct dds_curves step_curves;      // 244B = dds_curve[20] + num
  +0x764 struct ddi_curves limit_curr_curves;
  +0x858 struct ddt_coeff  term_coeff[20];
  +0x948 struct deep_dischg_limits config;   // 96B，见下
  +0x9a8 struct ddb_tcnt   cnts;             // {ratio; dischg;}
  +0x9b0 struct deep_dischg_sili_ic_alg_cfg sili_ic_alg_cfg;
  +0x9f8 s32 term_coeff_size;
  ...
};
struct ddb_curve  { s32 iterm; s32 vterm; s32 ctime; };            // 12B  ★关键
struct ddb_curves { struct ddb_curve limits[6]; s32 num; };        // 76B
struct dds_curve  { s32 temp;  s32 step;  s32 index; };            // 12B  ★关键
struct deep_dischg_limits {                                        // 96B
  +0x00 uv_thr; +0x04 target_uv_thr; +0x08 count_thr; +0x0c count_cali;
  +0x10 soc;                      // ← deep_spec,vbat_soc
  +0x14 term_voltage; +0x18 target_term_voltage;
  +0x1c ratio_shake; +0x20 sub_ratio_shake; +0x24 ratio_default;
  +0x28 ratio_status; +0x2c sub_ratio_status;
  +0x30 current_fcc_coeff; +0x34 current_soh_coeff;
  +0x38 spare_power_term_voltage; +0x3c volt_step;
  +0x40 index_r; +0x44 index_t; +0x48 step_status(bool);
  +0x50 ddrc_strategy_name[16]; +0x58 curr_max_ma; +0x5c curr_limit_ma;
};
```

宿主结构体 `oplus_mms_gauge`（L1474，size 9384=0x24A8）：

```
+0x00 dev; +0x08 gauge_ic; +0x10 level_shift_ic; +0x18 gauge_ic_comb; +0x28 voocphy_ic;
+0x30 gauge_topic;  +0x38 gauge_topic_parallel; +0x48 comm_topic; +0x50 wired_topic;
+0x58 vooc_topic; +0x60 err_topic; +0x68 parallel_topic; +0x70 batt_bal_topic;
+0x78 wls_topic; +0x80 cpa_topic; +0x88 ufcs_topic; +0x90 pps_topic; +0x98 comm_subs;
+0x528..+0xF40  struct delayed_work[20]（步长 0x88）
+0x748 delayed_work  ← oplus_gauge_deep_dischg_work  的宿主（work 指针 = chip+0x748）
+0x7d0 delayed_work  ← oplus_gauge_sub_deep_dischg_work
+0x858 delayed_work  ← deep_id / track
+0x8e0 delayed_work
+0x9f0 delayed_work
+0xFD0 struct deep_dischg_spec          ← chip->deep_spec
+0xFD4   = spec.counts      （deep_dischg_counts 显示值）
+0xFD8   = spec.sub_counts
+0x1A49 u8 wired_online;  +0x1A4A u8 wls_online;
+0x1A54 batt_temp_region; +0x1A58 child_num(电量计 IC 数);
+0x1A68 main_gauge; +0x1A6C sub_gauge; +0x1A70 ui_soc;
```

交叉验证：
- `oplus_gauge_show_deep_dischg_count` @0x18A940：`dev→oplus_mms_get_drvdata`→chip；
  读 `[chip+0xFD0]`（support），读 `[chip+0x1A58]`（IC 数），**返回值 = max(`[chip+0xFD4]`, `[chip+0xFD8]`)**（IC 数 ≥2 时取大者）。
- `oplus_gauge_set_deep_dischg_count` @0x18D788：`[chip+0xFD4]=v`；若 `dev==chip->dev` 再 `[chip+0xFD8]=v`。
- 工作函数里 `sub x10, x19, #0x748` 得到 chip，`[x19,#0x88C]` = chip+0xFD4 ✓ 三者自洽。

> 注：`BATT_DEEP_DISCHG_COUNT` / `BATT_DEEP_DISCHG_LAST_CC` **不是代码字符串**（`.rodata` 中不存在），
> 它们只出现在 `.BTF` 的字符串表里，是结构体/变量成员名。

### 1.2 数据流

```
上层 sysfs:  deep_dischg_counts_show  @0x04893C  → oplus_gauge_show_deep_dischg_count
             deep_dischg_counts_store @0x0489D0  → kstrtoint → oplus_gauge_set_deep_dischg_count

累加(唯一两个写入点)：
  oplus_gauge_deep_dischg_work      @0x190F30  → oplus_gauge_set_deep_dischg_count(dev, count+step)
  oplus_gauge_sub_deep_dischg_work  @0x1913E4  → oplus_gauge_set_deep_dischg_count(dev, count+step)

开机从 FG 读回：
  oplus_mms_gauge_sili_init @0x192E58
     ic_func(0x1C6=454, &v)，v 缺省 =10
     chip->deep_spec.counts     = v      ; str w8,[x19,#0xFD4] @0x192F94
     （若有 sub_gauge）同样取 454 → chip->deep_spec.sub_counts ; @0x193038

下沉到 FG/ADSP：
  oplus_gauge_set_deep_dischg_count → oplus_chg_ic_debug_get_func(ic, 0x1C7=455) → 调用
    → ic_auto_debug_oplus_ic_func_gauge_set_deep_dischg_count @0x10DC9C
    → oplus_chg_vg_set_batt_deep_dischg_count @0x1376FC
    → oplus_fg_set_batt_deep_dischg_count   @0x1E4A2C   （ADSP 邮箱：battery_chg_write 24B）
      或 nfg8011b_set_deep_dischg_counts    @0x0E130C   （I2C 直连）
读取：
  oplus_get_batt_deep_dischg_count @0x0C8BC4 → nfg8011b_get_deep_dischg_counts @0x0E0EAC
      I2C 从 0x3E 发 subcmd 0x7B(=123)，读 14B，取 buf[2]|buf[3]<<8（**16 位**），
      校验 buf[4]==~(buf[2]+buf[3])，并缓存在 chip->[0x5A8]
  ADSP 路径：oplus_fg_get_batt_deep_dischg_count @0x1E4884（24B 请求 + 共享 buffer 取值）
```

**结论（实测）**：累加算法只在 `oplus_gauge_deep_dischg_work` / `oplus_gauge_sub_deep_dischg_work` 里；
FG/ADSP 只承担**存储**（并且"计数"这一寄存器在 FG 内是 16 位）。
调用者全表（重定位扫描）里，写 count 的只有这两个 work + sysfs store。

---

## 2. 单位是什么？——不是"次"，是"加权累积分值"

1. **加法不是 +1，而是 +step**（@0x1912C4-0x1912CC）：
   ```
   1912c4: ldr  w8, [x19, #0x88c]   ; w8  = chip->deep_spec.counts（旧值）
   1912c8: add  w1, w8, w9          ; w1  = 旧值 + w9   ← w9 = step_curves[i].step
   1912cc: str  w1, [x19, #0x88c]   ; 写回
   191330: bl   oplus_gauge_set_deep_dischg_count   ; 并下沉到 FG
   ```
2. **step 取自温度表**（DT `deep_spec,count_step` = `[0,10,0, 350,12,1, 450,15,2, 530,20,3]`
   → (temp, step, idx)：0/35.0/45.0/53.0 ℃ 对应 **10 / 12 / 15 / 20**）：
   ```
   1910f4: mov  w9, #0xc
   1910f8: smaddl x9, w11, w9, x10   ; &step_curves[i]
   1910fc: ldr  w9, [x9, #0x4]       ; w9 = step_curves[i].step
   ```
3. **局部采样计数器**（`.bss+0x4500` = `oplus_gauge_update_deep_dischg.cnts`，副表为 `.bss+0x4504`）
   每轮 +1，达到 `batt_curves[region].limits[level].ctime` 才记一次账：
   ```
   1912ac: ldr  w11, [x11, #0x8]    ; w11 = limits[level].ctime  （DT 里是 5 或 2）
   1912b0: add  w12, w12, #0x1      ; cnts++
   1912b4: str  w12, [x8]
   1912b8: cmp  w12, w11
   1912bc: b.lt 0x191358            ; 未到阈值 → 不记账
   1912c0: str  wzr, [x8]           ; 到阈值 → cnts=0
   1912c4: ... count += step
   ```
4. **计数路径上没有任何除法/单位换算/限幅**（全 .text 里 `#0xfd4`/`#0xfd8` 的读点只有
   `oplus_gauge_show_deep_dischg_count` / `oplus_gauge_get_ratio_value` / `oplus_gauge_get_ddrc_status` /
   `oplus_iterm_timeout_work` / track profile，除法只出现在 `oplus_gauge_get_ratio_value`，
   且除的是 `spec.cc` 而不是计数本身）。上限只有 FG 侧 16 位（≤65535）。
   ```
   oplus_gauge_get_ratio_value @0x18C87C:
      spec.cc   = oplus_mms_get_item_data(dev, GAUGE_ITEM_CC(8), &v, 1)   // 库仑计
      if (gauge_type == 1) spec.cc = oplus_gauge_get_dec_cv_soh(dev)      // 或 SOH
      ratio = (1 <= cc < 5000) ? (counts==0 ? 100 : counts*10)
                               : (counts*10)/cc
   ```
   → 计数被当作**"剂量累积量"**，与库仑计/SOH 相除得到 `deep_spec.ratio`，供 DDRC 策略使用。
   `counts*10` 的 ×10 是唯一出现的"刻度"，说明该值本身是 1 分 = 1/10 刻度点的**累积分值**（推测）。

**单位结论：不是"次"。** 最贴切的描述是"深度放电当量累计分"，
一次满足条件并维持 `ctime` 个采样周期 → **+step（10/12/15/20）分**。

---

## 3. 什么情况下会增加？

### 3.1 前置门控

**(A) 启动门控** `oplus_gauge_deep_dischg_check` @0x191DD4（由 `oplus_mms_gauge_deep_dischg_init`、
wired/wls 插拔回调调用）：

```
191e04: ldr  x0, [x19, #0x48]        ; chip->comm_topic
191e0c: bl   oplus_mms_get_item_data  ; item = 11  → COMM topic 的 UI_SOC
191e18: str  w8, [x19, #0x1a70]       ; chip->ui_soc = v      ★字段名即 ui_soc
191e14: ldrb w9, [x19, #0xfd0]        ; deep_spec.support
191e1c: cbz  w9, ret                  ; 不支持直接返回
191e20: if (chip->wired_online || chip->wls_online)  → 取消
191e38: ldr  w9, [x19, #0x1928]       ; spec.config.soc (= deep_spec,vbat_soc, DT = 20)
191e3c: cmp  w8, w9
191e40: b.ge 0x191e84                 ; ui_soc >= 20 → 启动
191e44: (否则) cancel_delayed_work(chip+0x748); if (chip->sub_gauge) cancel_delayed_work(chip+0x7d0)
191e84: queue_delayed_work_on(0x20, system_wq, chip+0x748, 0)   ; 主
191ea0: if (chip->sub_gauge) queue_delayed_work_on(..., chip+0x7d0, 0)
191eb8: queue_delayed_work_on(..., chip+0x9f0, 0)
```

→ **只有"未插充电器（有线/无线都不在线）且 UI SOC ≥ 20%"时才运行。**

**(B) 每轮自检** `oplus_gauge_deep_dischg_work` @0x190F30 开头：

```
190f60: add  x8, x0, #0x1301          ; work(0x748)+0x1301 = chip+0x1A49 = wired_online
190f64: ldrb w9, [x8]
190f6c: cbnz w9, 0x190f78             ; 有线在线 → cnts=0 并 return（且不再自排队）
190f70: ldrb w8, [x8, #0x1]           ; wls_online
190f74: cbz  w8, 0x190fb4             ; 无线也不在线 → 继续
190f78: str  wzr, [.bss+0x4500]       ; cnts = 0
```

### 3.2 判定条件（核心）

每轮（**每 5 秒**，见 3.4）从 MMS topic 取三个量（`oplus_mms_get_item_data`）：
`GAUGE_ITEM_VOL_MIN(3)`、`GAUGE_ITEM_TEMP(6)`、`GAUGE_ITEM_CURR(5)`（从 `chip->gauge_topic = chip+0x30`），
UI_SOC（`comm_topic = chip+0x48`，item 11，update=1）。

```
191100: ldr  w20, [x19, #0x8b0]       ; chip+0xFF8 = spec.ddbc_tbatt.index_n（电池温度档位, 0..19）
191104: cmp  w20, #0x13 ; b.hi → brk  ; 越界
19110c: umaddl x11, w20, #0x4c, chip  ; &batt_curves[idx]（每项 76B）
191120: ldr  w12, [x11, #0x1098]      ; = batt_curves[idx].num（DT 每组 6 个 int → num=2）
191124: cmp  w12, #0x1 ; b.lt RESET   ; num<1 → cnts=0
191134: ldr  w13, [x11]               ; limits[0].iterm
191138: cmp  w8,  w13                 ; w8 = CURR
19113c: b.gt next                     ; curr > iterm → 试下一档
191140: ldr  w13, [x11, #0x4]         ; limits[0].vterm
191144: cmp  w22, w13                 ; w22 = VOL_MIN
191148: b.gt next
19114c: mov  x8, xzr                  ; level = 0
...（level 1..5 同构，偏移 +0xc / +0x18 / +0x24 / +0x30 / +0x3c）
191350: (全不匹配 / num<1) str wzr, [cnts]; → 只重排队，不记账
19129c: &limits[level]
1912ac: w11 = limits[level].ctime
1912b0: cnts++
1912b8: if (cnts < ctime) → 只重排队
1912c0: cnts = 0
1912c4: counts += step_curves[温度档].step     ← ★唯一 +step 的地方
191330: oplus_gauge_set_deep_dischg_count(dev, counts)
191338: oplus_gauge_get_ratio_value(dev)      ; 顺便刷新 ratio
```

**判据（伪代码）**

```c
void oplus_gauge_deep_dischg_work(work) {          // work = chip + 0x748
    if (!chip->deep_spec.support) return;
    if (chip->wired_online || chip->wls_online) { cnts = 0; return; }   // 充电中不计数
    ui_soc  = mms_get(comm_topic, COMM_ITEM_UI_SOC /*11*/, update=1); chip->ui_soc = ui_soc;
    vol_min = mms_get(gauge_topic, GAUGE_ITEM_VOL_MIN /*3*/, 0);
    tbat    = mms_get(gauge_topic, GAUGE_ITEM_TEMP    /*6*/, 0);
    curr    = mms_get(gauge_topic, GAUGE_ITEM_CURR    /*5*/, 0);

    step = step_curves_lookup(tbat);               // 默认 curves[0].step = 10
    region = chip->deep_spec.ddbc_tbatt.index_n;   // 0..3（cold/cool/normal/warm），温度档位
    R = &chip->deep_spec.batt_curves[region];

    int level = -1;
    for (i = 0; i < R->num; i++)
        if (curr <= R->limits[i].iterm && vol_min <= R->limits[i].vterm) { level = i; break; }

    if (level < 0) { cnts = 0; }                   // 条件不成立 → 采样计数清零
    else if (++cnts >= R->limits[level].ctime) {   // 连续 ctime 次成立
        cnts = 0;
        chip->deep_spec.counts += step;            // ★ +10/12/15/20
        oplus_gauge_set_deep_dischg_count(chip->dev, chip->deep_spec.counts);
        oplus_gauge_get_ratio_value(chip->dev);
    }
    queue_delayed_work_on(0x20, system_wq, work, 1250);   // 重新排队
}
```

### 3.3 本机实际 DT 参数（dtbo.img `/fragment@52/__overlay__/oplus,mms_gauge`）

| 属性 | 值 | 落到 |
|---|---|---|
| `deep_spec,support` | (空 = true) | `spec.support` (+0xFD0) |
| `deep_spec,uv_thr` | 2800 | `config.uv_thr` (+0x1918) |
| `deep_spec,count_thr` | **50**（缺省 1） | `config.count_thr` (+0x1920) — **只被 push 给 ADSP/算法，不参与内核累加** |
| `deep_spec,count_cali` | 未定义 → 0 | `config.count_cali` (+0x1924)（sysfs `deep_dischg_count_cali`=0 ✓） |
| `deep_spec,vbat_soc` | **20**（缺省 10） | `config.soc` (+0x1928) ★启动门控 |
| `deep_spec,volt_step` | 20（缺省 100） | `config.volt_step` (+0x1954) |
| `deep_spec,ratio_thr` | 未定义 → 30 | `ratio_shake`/`sub_ratio_shake`/`ratio_default`（sysfs `deep_dischg_ratio_thr`=30 ✓） |
| `deep_spec,count_step` | `[0,10,0, 350,12,1, 450,15,2, 530,20,3]` | `step_curves` (+0x1640, num@+0x1730=4) |
| `deep_spec,ddbc_curve/deep_spec,ddbc_temp_cold` | `[500,3200,5, 10000,3100,2]` | `batt_curves[0]` (+0x1050) |
| …`ddbc_temp_cool` | `[500,3300,5, 10000,3200,2]` | `batt_curves[1]` (+0x109C) |
| …`ddbc_temp_normal` | `[500,3400,5, 10000,3350,2]` | `batt_curves[2]` (+0x10E8) |
| …`ddbc_temp_warm` | `[500,3400,5, 10000,3350,2]` | `batt_curves[3]` (+0x1134) |
| `ddbc_curve/oplus,temp_range` | `[-100, 50, 200]` (=-10.0/5.0/20.0 ℃) | 温度档位划分 |

每个 `ddbc_temp_*` 6 个 int = 2 条 `ddb_curve`：
- `limits[0] = {iterm=500, vterm=3400, ctime=5}`
- `limits[1] = {iterm=10000, vterm=3350, ctime=2}`

即（warm 档，T≥20℃，最常发生）：
- 轻载（curr ≤ 500）且 `VOL_MIN ≤ 3400 mV` → level 0，需连续 **5** 次（=25 s）→ **+10**（T<35℃）
- 重载（curr > 500）且 `VOL_MIN ≤ 3350 mV` → level 1，需连续 **2** 次（=10 s）→ **+10**

（CURR 符号约定未在反汇编中确定；设备 `current_now = -212`（放电为负），若 `GAUGE_ITEM_CURR` 同号则
`curr ≤ 500` 恒真、level 1 不可达 —— **此处为不确定点，见 §5**。）

### 3.4 周期

```
19135c: mov  w21, #0x4e2        ; 1250
1913c0: ldr  x1, [system_wq]
1913c8: mov  x2, x19            ; &this delayed_work
1913cc: mov  x3, x21            ; delay = 1250 jiffies
1913d0: bl   queue_delayed_work_on
```
`CONFIG_HZ=250`（实测 `/proc/config.gz`）→ **1250 jiffies = 5 s**。
即：**"连续 ctime 次" = 10 s（level 1）或 25 s（level 0）持续满足条件才 +step**。

---

## 4. 为什么 1758 而 cycle_count 只有 344？

1. **单位不同（主因）**：`cycle_count` 是"等效完整充放电循环数"，一次满充满放 +1；
   `deep_dischg_counts` 是"深度放电当量累积分值"，一次成立 **+10（或 12/15/20）**。
   即便两者的事件数相同，后者也会是前者的 ~10 倍量级。
2. **计数对象不同**：`cycle_count` 由库仑积分/放电深度统计得出（每次循环都 +1）；
   深度放电计数的条件苛刻得多（`VOL_MIN` 掉到 3.35–3.40 V 附近且持续 10–25 s，且不能插着充电器，且 UI SOC ≥ 20%），
   正常用户几周也未必触发一次。因此 1758 若真是本机跑出来的，意味着大量深度放电当量；
   而**本机长期不变**说明条件未被触发。
3. **持久化位置不同**：`deep_spec.counts` 在内核初始化时由
   `oplus_mms_gauge_sili_init` 通过 IC func 454 **从电量计（FG/ADSP）读回**（读取失败时缺省 **10**），
   又通过 IC func 455 写回。也就是说 **1758 这个值存在电量计里**，可跨刷机/清 data 保留下来，
   很可能是**产线/老化测试或前序状态写入的遗留值**（推测——无法从 .ko 判定其历史来源）。
4. 反过来说：`1758` 不能被解释为"1758 次深度放电"。按最小步进 10 计，等价于 ≥176 次"满额"记账；
   按当量比例与 `SOH` 相比，它被 `oplus_gauge_get_ratio_value` 折算为 `ratio = counts*10/cc(或soh)`
   再喂给 DDRC 策略，属于"老化/损耗评估量"。

---

## 5. 置信度与不确定点

**高置信（直接反汇编/BTF/DT/sysfs 互证）**
- 计数宿主：`oplus_mms_gauge.deep_dischg_spec.counts`（chip+0xFD4），sub 在 +0xFD8，sysfs 取二者较大值。
- 累加逻辑在**内核** `oplus_gauge_deep_dischg_work` / `oplus_gauge_sub_deep_dischg_work`；
  FG/ADSP 只做存储（IC func 454 读 / 455 写；I2C 直连路径 `nfg8011b_*` 读 16 位 subcmd 0x7B）。
- 增量是 **+step（10/12/15/20）而非 +1**，step 由温度档位查 `deep_spec,count_step` 表。
- 记账需要局部采样计数连续达到 `ddb_curve.ctime`（DT 为 5 或 2）；采样周期 1250 jiffies = 5 s。
- 判据为 `curr ≤ iterm && vol_min ≤ vterm`（`ddb_curve = {iterm, vterm, ctime}`），
  并按 `ddbc_tbatt.index_n`（电池温度档，0..3）选择曲线组。
- 运行前置：`deep_spec.support`、非充电中（`wired_online||wls_online` 即退出）、UI SOC ≥ `deep_spec,vbat_soc(=20)`。
- `config.count_thr(=50)` **不**参与内核累加（只被 `oplus_mms_gauge_push_vbat_uv` 记录日志、
  被 `oplus_gauge_update_ddrc_data` push 给 DDRC/ADSP 算法）。

**中置信（推断）**
- IC func id 454 = GET_DEEP_DISCHG_COUNT、455 = SET_DEEP_DISCHG_COUNT：由
  `oplus_mms_gauge_sili_init` 用 454 读入 counts、`oplus_gauge_set_deep_dischg_count` 用 455 写出推断而来，
  未直接读到函数表条目。
- `COMM_ITEM(11) = UI_SOC`：由"读出后立即存入 `chip->ui_soc`(BTF 成员名)"推得。
- 温度表`[0,350,450,530]` 单位为 0.1 ℃。

**不确定点**
1. **CURR 符号约定**：`curr ≤ iterm` 的两个档（500 / 10000）在放电为负时 level 0 恒胜、level 1 不可达；
   若放电为正，则 level 0 = 轻载浅放（5 次），level 1 = 重载深放（2 次），逻辑更自洽。**未能从 .ko 判定**。
2. **FG/ADSP 是否也会自行累加**：.ko 只显示内核会写该值；无法从模块证明 FG 固件不做自己的记账
   （DT 把 `count_thr` 推给算法，暗示 ADSP 侧也可能有相关逻辑）。
3. **1758 的来源**：无法从 .ko 判定（产线写入 / 历史深度放电 / FG 老化）。
4. `step_curves` 温度查找在"温度低于表首项(0)"时回退到 index 0（`and w11, w10, w10, asr #31` → 0），
   而非表尾；若源码意图是"取表尾"则为编译器语义差异，已按反汇编描述。

---

## 6. 关键反汇编片段索引

| 地址 | 内容 |
|---|---|
| 0x190F54-0x190F80 | `if (wired_online ‖ wls_online) { cnts=0; return; }` |
| 0x190FC4-0x191010 | item 11（comm_topic，update=1）→ `chip->ui_soc`；item 3 → VOL_MIN |
| 0x191034-0x191078 | item 6 → TEMP；item 5 → CURR |
| 0x19107C-0x1910FC | 温度查找 step_curves[i].temp → `.step` |
| 0x191100-0x191108 | `region = spec.ddbc_tbatt.index_n`（chip+0xFF8），边界 0..19 |
| 0x191120-0x191150 | `num = batt_curves[region].num`；level 0 判据 |
| 0x191154-0x191298 | level 1..5 判据（+0xc/+0x18/+0x24/+0x30/+0x3c） |
| 0x19129C-0x1912CC | `cnts++`；`if (cnts >= ctime) { cnts=0; counts += step; }` |
| 0x1912D0-0x191330 | 选 dev（child_num/sub_gauge）→ `oplus_gauge_set_deep_dischg_count` |
| 0x191338 | `oplus_gauge_get_ratio_value` |
| 0x191384-0x1913D4 | track 上传 `$$track_reason@@deep_dischg$$trange@@%d` + `queue_delayed_work_on(...,1250)` 自排队 |
| 0x191E04-0x191EC8 | `deep_dischg_check`：ui_soc / support / online / soc 门控 + 启停 work |
| 0x192F90-0x193038 | `oplus_mms_gauge_sili_init`：IC func 454 → `spec.counts` / `spec.sub_counts`（缺省 10） |
| 0x18A964-0x18A980 | `show_deep_dischg_count`：`max(counts, sub_counts)` |
| 0x18D7FC-0x18D86C | `set_deep_dischg_count`：写 0xFD4（dev==chip->dev 时也写 0xFD8） |
| 0x18C9A8-0x18C9E0 | `ratio = counts*10 / cc(或 soh)` |
| 0x0E0F58-0x0E1060 | `nfg8011b_get_deep_dischg_counts`：subcmd 0x7B，16 位 + 校验和 |
| 0x1E4A6C-0x1E4AC4 | `oplus_fg_set_batt_deep_dischg_count`：ADSP 24B 写 |
| 0x16D274-0x16D2BC | `oplus_mms_gauge_probe`：`INIT_DELAYED_WORK(..., oplus_gauge_deep_dischg_work)` |

*生成：逆向子代理（session-53d49daa 的子代理）*
