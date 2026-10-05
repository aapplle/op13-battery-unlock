# RE-A：ColorOS 16.0.5.701 / 6.6.89 驱动「电量计深度终止电压」计算路径

驱动：oplus_chg_v2.ko（md5 c6fedbc820fac7c6b9c3593b4020b215，aarch64，符号表完整）
工具：/usr/lib/llvm-18/bin/llvm-objdump + pyelftools/capstone
说明：.ko 的 ELF 中所有 section 的 sh_addr = 0，所以「符号地址」= section 内偏移；
R_AARCH64_ADR_PREL_PG_HI21 / ADD_ABS_LO12_NC 重定位的 addend 是相对于 sym 所在 section
的偏移，必须用 sec.data()[addend] 取串，不能用绝对地址。下文地址均为 .text 内偏移。

> ⚠️ **重要更正（见文末「修订 v2」）**：本文 §2/§4/§6 中的 DT 表数据是把**大端** u32
> 误按小端解析得到的，**表格内容有误**；§0/§4 中「驱动实发 3350 ⇒ 前提不成立」的结论
> **亦已推翻**（3350 是模块 uv2800 写入后的回读值）。
> 请以文末 **「修订 v2：3250 的可行域与下发时机」** 为准：其中包含重新逐字节解析的
> 24 张正确表、counts=1758 下产出 3250 的全部 6 种组合、temp/ratio 档位条件、
> 以及 DDRC 下发周期与 op 映射的修正。
> 仍然有效的部分：函数链（§1）、选择算法骨架与 get_data 字段（§3）、
> 表结构 stride（§2 的运行期私有区布局）、v_hi 出局（§3/§4-Q3）、term_coeff 用途（§4-Q5）。

---

## 0. 结论速览

| 项 | 结论 | 置信度 |
|---|---|---|
| DDRC 表选择维度 | ratio_region(行) × temp_region(列)，5×4 子表 | 已证实 |
| 4 元组第 1 字段与谁比较 | 与「比值/深度放电比例」比较（非 counts 绝对值） | 已证实（比较量来自 item 0x1e） |
| 4 元组哪一段最终成为终止电压 | v_hi（第 3 字段） | 已证实 |
| deep_spec,term_coeff 用途 | 被 oplus_gauge_parse_deep_spec 解析，供分区索引使用；非终止电压直接输出 | 部分证实（见 §5） |
| 用 35.6°C / counts=1758 复现 3250 | 不能；本驱动 DDRC 路径给出 v_hi=3350（与模块 DT 走查一致） | 已证实 |
| 3250 来源 | 本驱动 DDRC 路径在给定输入下不产生 3250 | 待确认 |

注意：与任务书假设相反 —— 反汇编 + 实机 dmesg 都指向 **驱动实发 3350**，而非 3250。
详见 §4 与 §5.4。

---

## 1. 函数链（地址 + 作用）

    oplus_mms_gauge_probe / oplus_mms_gauge_init_work
      +- oplus_gauge_parse_deep_spec        0x18f7f8  解析 deep_spec,* 属性
      |    |                                          (term_coeff / ddrc_strategy_name / count_step...)
      |    +- oplus_chg_strategy_alloc_by_node  间接    vtable 调用
      |    |    +- ddrc_strategy_alloc_by_node  0x19b7d0 (v1,0x7ac) 解析 DT 5x4 子表
      |    |    +- ddrc_strategy_alloc_by_node  0x19c648 (v2,0x76c)
      |    +- oplus_gauge_get_battery_type_str  -> child "silicon_p_770"
      |
      +- oplus_gauge_deep_temp_work           0x19192c  (0x4a4) 周期刷新 DDRC 状态
           +- oplus_gauge_get_deep_dischg_temperature 0x18c700  取温度
           +- oplus_gauge_ddrc_get_temp_region 0x18c7f0 (0x88)  -> temp_region
           +- oplus_gauge_get_ddrc_status      0x18cd28 (0x808) 主选择逻辑
                +- oplus_gauge_get_ratio_value 0x18c87c -> ratio_region
                +- oplus_gauge_update_ddrc_data 0x18cab0 (0x274) -> strategy->get_metadata
                +- oplus_chg_ic_debug_get_func(ic, 0x1ce)
                     = ic_auto_debug_oplus_ic_func_gauge_get_deep_term_volt 0x10e0bc
                     -> 读 IC 侧 deep_term_volt（模块 hook 的正是这条）

策略框架（通用）：

    oplus_chg_strategy_init          -> ddrc_strategy_init        0x19c054 (v1)
    oplus_chg_strategy_get_metadata  -> ddrc_strategy_get_metadata 0x19c578 (v1)
    oplus_chg_strategy_get_data      -> ddrc_strategy_get_data    0x19c4dc (v1)

v1 / v2 两套符号（.data 里两张 ddrc_strategy_desc，各 0x58 字节）：

| 描述符 | alloc | alloc_by_node | release | init | get_data | get_metadata |
|---|---|---|---|---|---|---|
| v1 .data+0x10c10 | 0x19b7c4 | 0x19b7d0 | 0x19bf80 | 0x19c054 | 0x19c4dc | 0x19c578 |
| v2 .data+0x10c68 | 0x19c63c | 0x19c648 | 0x19cdb8 | 0x19d018 | 0x19d4b8 | 0x19d554 |

**本机用 v1**：oplus_gauge_parse_deep_spec @0x19014c 读 deep_spec,ddrc_strategy_name，
与 "ddrc_curve_v2" 做 strncmp(...,13)（0x190154）；不等则 strb wzr,[x24,#3]（0x190160）
-> 走非 v2 分支 -> v1。实机 DT 实测该属性 = "ddrc_curve"（11 字节 + NUL）=> v1 生效。

---

## 2. DT 解析（v1: ddrc_strategy_alloc_by_node 0x19b7d0）

循环 6 次（x28: 0 -> 0x240，步进 0x60），每次处理一个 strategy_ratio_range_* 子节点：

    属性名（0x19b8c8 起，由 /tmp/res.py 实测解析）:
      "oplus,temp_type"      -> 私区 +0x278
      "oplus,ratio_range"    -> 5 项，写入私区 +0x258   (0x19b900, 0x19b930)
      "oplus,temp_range"     -> 3 项，写入私区 +0x26c   (0x19b948, 0x19b970)
      每个 ratio-range 子节点（0x19b9c0 of_get_child_by_name）:
        "strategy_temp_cold"   -> 指针存 base+0x18, 元素数存 base+0x28
        "strategy_temp_cool"   -> 指针存 base+0x30, 元素数存 base+0x40
        "strategy_temp_normal" -> 指针存 base+0x48, 元素数存 base+0x58
        "strategy_temp_warm"   -> 指针存 base+0x60, 元素数存 base+0x70

元素数 = 原始 u32 个数 / 4，即按 4 元组切分（0x19b9ec: lsl w3,w21,#2; asr w8,w3,#4）。

v2（0x19c648）结构不同：私有区仅 0x90 字节，oplus,ratio_range 存到 +0x48（5 项），
oplus,temp_range 存到 +0x60，oplus,gauge_topic_name / oplus,temp_type 在 +0x6c。
本机不走这条。

### 运行期私有区布局（v1，由 0x19c3a4 反推）

    19c3a4:  umaddl x9, w22, w9(=0x60), x19   ; ratio 维步进 0x60
    19c3a8:  umaddl x9, w8,  w10(=0x18), x9   ; temp  维步进 0x18
    19c3ac:  stp    w22, w8, [x9, #0x20]
    19c3b0:  add    x11, x9, #0x18
    19c3c0:  str    x11, [x19, #0x10]         ; priv[0x10] = 选中子表

即 priv[0x10] = base + ratio_region*0x60 + temp_region*0x18 + 0x18，
指向该 (ratio,temp) 组合的 4 元组数组。

---

## 3. 选择算法（伪代码）

### 3.1 ddrc_strategy_init 0x19c054 —— 选出 ratio_region

    item = oplus_mms_get_item_data(gauge_mms, 0x1e, &ratio)   ; 0x19c0ac, w1=0x1e
    if (ret < 0) goto err;

    // 0x258/0x25c/0x260/0x264/0x268 = oplus,ratio_range[0..4] = [20,30,50,70,90]
    if (ratio <  priv[0x258]) ratio_region = 0;      // 0x19c0b4..0x19c0c4
    else if (ratio < priv[0x25c]) ratio_region = 1;  // 0x19c114..0x19c120
    else if (ratio < priv[0x260]) ratio_region = 2;  // 0x19c2a4..0x19c2b0
    else if (ratio < priv[0x264]) ratio_region = 3;  // 0x19c2c0..0x19c2cc
    else if (ratio < priv[0x268]) ratio_region = 4;  // 0x19c32c..0x19c338
    else                          ratio_region = 5;
    // 另 0x19c178: cmp w8,#4 / b.lt 0x19c39c -> 来自 item 的值 >=4 直接落 map 表

### 3.2 ddrc_strategy_init 同一函数 —— 选出 temp_region，再落表

    temp = oplus_mms_get_item_data(gauge_mms, 0x1f, &t);     ; 0x19c168, w1=0x1f
    if (temp ok && temp >= 0 && temp < 4) temp_region = temp; ; 0x19c170..0x19c17c
    priv[0x10] = base + ratio_region*0x60 + temp_region*0x18 + 0x18;

priv[0x278] = oplus,temp_type（0x19b8c8 读，默认 1）：
  - temp_type == 0 -> 走 battery temp（item 6，0x19c1bc w1=6）
  - temp_type == 1 -> 走 shell temp（item 0x0e，0x19c218 w1=0xe, w3=0）
  - 其它 -> "not support temp type"(0x49d52) 报错

### 3.3 ddrc_strategy_get_data 0x19c4dc —— 取值入口

    19c4f8:  ldr  x8, [x8, #0x10]      ; x8 = strategy->priv[0x10] = 选中子表基址
    19c4fc:  ldp  x10, x9, [x8, #0x8]  ; x10 = [x8+8], x9 = [x8+16]
    19c500:  ldr  x8, [x8]             ; x8  = [x8+0]
    19c504:  str  x8,  [x1]            ; out[0] = [x8+0]
    19c508:  stp  x10, x9, [x1, #0x8]  ; out[2] = [x8+8], out[1] = [x8+16]
    19c50c:  b    19c54c  -> ret w0=0  ; 12 字节输出

关键：输出 12 字节 = 选中子表的前 3 个 u32，**第 1 个字段被跳过**。

### 3.4 oplus_gauge_get_ddrc_status 0x18cd28 —— 消费者

    18cd88..18cdc4  ratio_value = oplus_gauge_get_ratio_value(...)  主/副 gauge 各一次
    18cdf8          ratio_value = oplus_gauge_get_ratio_value(x0)
    18ce18          oplus_gauge_update_ddrc_data(ic, &x, &y)        内部 vote 起效值
    18ce1c/18ce30   get_effective_result(voter)                    <- 最终生效数值
    18ce4c..18ce84  IC 侧现值: oplus_chg_ic_debug_get_func(ic,0x1ce) <- 模块 hook 的这条
    18ceb8:         sub w8, w20, w21 ; add w8, w8, w22
    18cf10          scnprintf(...)  -> sysfs/日志
    18d0a0..18d15c  vote() 上报（参数从 priv+0x19e8/+0x1a00 的 16 字节条目取）

每轮从 priv[0x19e8] + idx*16 与 priv[0x1a00] + idx*16 各取两个 u32（[+8] 与 [+4]）
分别 vote 给两个 voter —— 即选中子表的 2 个电压字段分别作为下限/上限两个票。

---

## 4. 五问逐条回答

### Q1 驱动算「电量计深度终止电压」的完整路径

已证实：oplus_gauge_parse_deep_spec(0x18f7f8) -> ddrc_strategy_alloc_by_node(0x19b7d0,v1)
-> 每周期 oplus_gauge_deep_temp_work(0x19192c) -> oplus_gauge_get_ddrc_status(0x18cd28)
-> oplus_gauge_update_ddrc_data(0x18cab0) -> ddrc_strategy_init(0x19c054)
-> ddrc_strategy_get_data(0x19c4dc) -> 12 字节（3 个 u32）
-> vote -> oplus_set_deep_term_volt -> IC
（ADSP 侧 oplus_fg_set_deep_term_volt 0x1e4b68 / oplus_fg_get_deep_term_volt 0x1e4ca4，
打印 OPLUS_CHG[ADSP] ... deep_term_volt=%d，见 §5.4）。
模块 hook 的 oplus_chg_ic_debug_get_func(ic,0x1ce) 即 0x18ce58，对应
ic_auto_debug_oplus_ic_func_gauge_get_deep_term_volt(0x10e0bc)。

### Q2 表怎么选行：ratio 与温度如何参与、第 1 字段与谁比较

已证实：
- 行（ratio_region）：由 item 0x1e（深度放电比例，与 sysfs deep_dischg_ratio_thr 同族）
  与 oplus,ratio_range = [20,30,50,70,90] 做逐级「小于」比较 -> 0..5（0x19c0b4 起）。
- 列（temp_region）：由 item 0x1f（温度，按 oplus,temp_type 选 battery/shell 来源）
  直接作为列索引，合法域 0..3（0x19c170 起）。
- 第 1 字段：在 ddrc_strategy_get_data 里被跳过（ldp/ldr 从 +8 开始读）。
  它只在建表/查找阶段作为该行的门槛，**不是运行时被比较的量**。

### Q3 4 元组里谁最终成为终止电压

已证实：v_hi（选中子表的第 2 个电压字段；若标注为 (thr,v_lo,v_hi,idx) 则为 v_hi）。
理由：
1. get_data 输出子表前 3 个 u32（0x19c4fc-0x19c508），第 1 个被跳过。
2. 消费者把两个电压字段作为同一 voter 的上下限两个票（0x18d0a0-0x18d15c）。
3. DT 实测 warm 行 = (0,3000,3060,0) (500,3000,3060,1) (1000,3100,3150,2)
   (1000,3200,3250,3) (1500,3300,3350,4)：3250 只作为 v_hi 出现在第 4 行，
   3350 只作为 v_hi 出现在第 5 行。若输出 v_lo，值域只有 3000-3300，永远出不了 3250/3350。
   => v_hi 是终止电压。
4. idx 是 0..5 自增序号，与电压无关（仅用于 vote 表索引）。

### Q4 用实测输入能否复现 3250

已证实：不能。按上面的算法：

    温度 35.6°C；DT oplus,temp_range = [0xFFFFFFCE,100,350] = [-50,10.0,35.0] °C(0.1°C)
      35.6 > 35.0 -> 落在最后一个区间 -> temp_region = 3 (warm)
    ratio : sysfs deep_dischg_ratio_thr = 30
      ratio_range = [20,30,50,70,90]
      30 >= 20 -> 不是 region 0
      30 >= 30 -> 不是 region 1     （注意是 < 才落）
      30 <  50 -> ratio_region = 2   (mid 档)
    查表 (ratio_region=2 = strategy_ratio_range_mid, temp_region=3 = warm):
      DT mid/warm = (0,3000,3060,0) (100,3100,3150,1) (300,3200,3250,2) (600,3300,3350,3)
    第 1 字段（计数阈值）在运行期不参与 get_data；
    最终取值由 0x18cd28 的 vote/effective_result 决定，落点 v_hi 属于 {3060,3150,3250,3350}

若 deep_dischg_counts = 1758 被用作行内计数阈值（模块 DT 走查的假设）：
  strategy_ratio_range_mid/warm 阈值列为 [0,100,300,600]，1758 超过全部
  => 取最后一行 => v_hi = 3350（与模块 3350 一致，不是 3250）。
  要拿到 3250 必须落 mid/warm 第 3 行 (300,3200,3250,2)，
  即需 300 <= counts < 600；1758 不满足。
  用「取首个满足 counts < thr」的上界语义也不行（1758 越过全部）。

因此：在给定输入下，本驱动 DDRC 路径得到的 v_hi 是 3350，不是 3250。

### Q5 deep_spec,term_coeff 到底谁在用

已证实（谁解析）：唯一解析点是 oplus_gauge_parse_deep_spec(0x18f7f8)：
- 0x18f860/0x18f8b0: of_property_count_elems_of_size(node,"deep_spec,term_coeff",4)
  -> 0x18f87c cmp w3,#0x3e（上限 62）、0x18f898 检查 count % 3 == 0
  -> 0x18f8c0 lsr w21,w8,#9 即 count*0xAB>>9 ~= count/3（3 元组）
  -> 0x18f8c8 add x2,x19,#0x1828 存放；0x18f8d0 str w21,[x19,#0x19c8] 存个数
  错误串 "Count deep spec term_coeff failed, rc=%d" (.rodata.str1.1+0x1e907)
- 0x190068: deep_spec,ddrc_strategy_name（默认 "ddrc_curve"，0x190140）
- 0x19014c: strncmp(name,"ddrc_curve_v2",13) -> 决定 v1/v2

实机 DT 实测（/proc/device-tree/soc/oplus,mms_gauge/deep_spec,term_coeff）：

    u32[21] = {0x0000B80B,0x0000C800,0x00000000,
               0x00001C0C,0x0000012C,0x00000002,
               0x00004E0C,0x0000015E,0x00000003,
               0x0000B20C,0x000001C2,0x00000005,
               0x0000E40C,0x000001F4,0x00000007,
               0x00002A0D,0x00000258,0x00000008,
               0x0000480D,0x00000258,0x00000008}
    => 7 个 3 元组，第1字段 0x0C1C-0x0D48 (=3100-3400，mV 量级)，
       第2字段 300-600，第3字段 0,2,3,5,7,8,8

deep_spec,count_step（实测，4 元组）：

    (0, 10, 0, 0) (350, 12, 1, 1) (450, 15, 2, 2) (530, 20, 3, 3)

结论（区分等级）：
- 已证实：term_coeff 由 oplus_gauge_parse_deep_spec 读入 priv+0x1828，个数存 priv+0x19c8，
  按 3 元组切分。
- 已证实：它与 deep_spec,count_step 一起，被 oplus_gauge_get_ddrc_status /
  oplus_gauge_update_ddrc_data 用于计算「深度放电比例/分区索引」（即 item 0x1e 那条
  数据流），从而决定 ratio_region（DDRC 表的行）。
- 推测：term_coeff 与 oplus_get_three_level_term_volt(0x1e6ae4) 那条路没有直接调用关系
  —— get_three_level_term_volt_show(0x3f89c) 实测输出全 0，且
  oplus_gauge_get_three_level_term_volt(0x18c0a0) 返回 rc=0xfffffdf4(-524,-ENODEV)，
  说明该路在本机未使能，不是 3250 的来源。
- 推测：term_coeff 三段的分工为 (电压候选值, 计数/比例门槛, 序号)；
  未在反汇编中直接看到它被赋给终止电压输出，故不能断言它是终止电压来源。

---

## 5. 关键反汇编片段

### 5.1 ddrc_strategy_get_data 0x19c4dc

    19c4dc:  paciasp
    19c4e8:  cbz  x0, 0x19c510
    19c4ec:  cbz  x1, 0x19c538
    19c4f0:  mov  x8, x0
    19c4f4:  mov  w0, wzr
    19c4f8:  ldr  x8, [x8, #0x10]      ; x8 = strategy->priv[0x10]
    19c4fc:  ldp  x10, x9, [x8, #0x8]
    19c500:  ldr  x8, [x8]
    19c504:  str  x8, [x1]             ; out[0]
    19c508:  stp  x10, x9, [x1, #0x8]  ; out[1], out[2]
    19c50c:  b    19c54c
    19c548:  mov  w0, #-0x16           ; -EINVAL
    19c54c:  ldp  x29, x30, [sp], #0x10
    19c550:  autiasp
    19c554:  ret

### 5.2 ddrc_strategy_init 0x19c3a4（表选择算术）

    19c39c:  mov  w9, #0x60
    19c3a0:  mov  w10, #0x18
    19c3a4:  umaddl x9, w22, w9, x19    ; ratio 维步进 0x60
    19c3a8:  umaddl x9, w8,  w10, x9    ; temp  维步进 0x18
    19c3ac:  stp  w22, w8, [x9, #0x20]
    19c3b0:  add  x11, x9, #0x18
    19c3b4:  mov  w9, w22
    19c3b8:  ldr  w10, [x21]            ; oplus_log_level
    19c3bc:  mov  w8, w8
    19c3c0:  str  x11, [x19, #0x10]     ; <- priv[0x10] = 选中子表
    19c3c4:  cmp  w10, #4
    19c3c8:  b.gt 0x19c404
    19c3cc:  cmp  w10, #2
    19c3d0:  b.ge 0x19c42c
    19c3d4:  mov  w0, wzr
    19c3d8:  ... ret

### 5.3 ratio 分档 0x19c0b4 起

    19c0b4:  ldr  w8, [sp, #0x10]       ; ratio
    19c0b8:  ldr  w9, [x19, #0x258]     ; ratio_range[0]
    19c0bc:  cmp  w8, w9
    19c0c0:  b.hs 0x19c114
    19c0c4:  mov  w22, wzr
    19c114:  ldr  w9, [x19, #0x25c]     ; ratio_range[1]
    19c118:  cmp  w8, w9
    19c11c:  b.hs 0x19c2a4
    19c120:  mov  w22, #1
    19c2a4:  ldr  w9, [x19, #0x260]     ; ratio_range[2]
    19c2a8:  cmp  w8, w9
    19c2ac:  b.hs 0x19c2c0
    19c2b0:  mov  w22, #2
    19c2c0:  ldr  w9, [x19, #0x264]     ; ratio_range[3]
    19c2c4:  cmp  w8, w9
    19c2c8:  b.hs 0x19c32c
    19c2cc:  mov  w22, #3
    19c32c:  ldr  w9, [x19, #0x268]     ; ratio_range[4]
    19c330:  cmp  w8, w9
    19c334:  mov  w8, #4
    19c338:  cinc w22, w8, hs           ; 4 或 5

### 5.4 终止电压写出 IC 的 ADSP 侧日志（实机 dmesg 直接证据）

    [  756.975400] OPLUS_CHG[ADSP]([oplus_fg_get_deep_term_volt][11937]): oplus_fg_get_deep_term_volt, deep_term_volt=2540
    [  757.522666] OPLUS_CHG[ADSP]([oplus_fg_set_deep_term_volt][11903]): oplus_set_deep_term_volt rc=0, volt = 3350
    [  757.539179] OPLUS_CHG[ADSP]([oplus_fg_get_deep_term_volt][11937]): oplus_fg_get_deep_term_volt, deep_term_volt=3350
    [ 1542.371738] OPLUS_CHG[OPLUS_SILI]([oplus_gauge_ddrc_temp_thr_update][1226]): now=2, pre=3, p[3]update thr[2] to 370

驱动实发是 3350（不是 3250），且紧随其后的读取也是 3350。

对应反汇编（oplus_fg_set_deep_term_volt 0x1e4b68 / get 0x1e4ca4）：

    0x1e4c4c: STR '..3[INFO]: OPLUS_CHG[ADSP]([%s][%d]): oplus_set_deep_term_volt rc=%d, volt = %d'
    0x1e4c60: STR 'oplus_fg_set_deep_term_volt'
    0x1e4e0c: STR '..6[INFO]: OPLUS_CHG[ADSP]([%s][%d]): oplus_fg_get_deep_term_volt, deep_term_volt=%d'

### 5.5 模块 hook 的 op 0x1ce 解析

    ic_auto_debug_oplus_ic_func_gauge_get_deep_term_volt 0x10e0bc:
      10e0e8:  mov  w1, #0x1ce
      10e104:  blr  x8                 ; ic->ops->get_func(op)
      10e114:  mov  w1, #0x1ce
      10e140:  blr  x21                ; 调真正的 getter(ic, &volt)
    oplus_gauge_get_ddrc_status 0x18cd28:
      18ce54:  mov  w1, #0x1ce
      18ce84:  blr  x8                 ; 同一 op -> 读 IC 侧 deep_term_volt
    同理 oplus_mms_gauge_get_sili_ic_alg_term_volt 0x18e760:
      18e878:  mov  w1, #0x1d2         ; SILI 算法终止电压是**另一个** op 0x1d2

---

## 6. 实机取证（C16.0.5.701，2026-10-05）

    battery_type            = silicon_p_770
    gauge_type              = 0
    battery_soh             = 100
    battery temp            = 34.9 °C   (battery/temp = 349)
    deep_dischg_counts      = 1758       (/sys/class/oplus_chg/common/)
    deep_dischg_ratio_thr   = 30
    deep_dischg_count_cali  = 0
    get_three_level_term_volt = first_term_volt=0,second_term_volt=0,third_term_volt=0

DT（/proc/device-tree/soc/oplus,mms_gauge/）：

    deep_spec,ddrc_strategy_name = "ddrc_curve"      <- 决定走 v1
    deep_spec,count_thr          = 50 (0x32)
    deep_spec,count_step         = (0,10,0,0) (350,12,1,1) (450,15,2,2) (530,20,3,3)
    deep_spec,uv_thr             = 2800 (0xAF0)
    deep_spec,vbat_soc           = 20
    deep_spec,volt_step          = 20
    ddrc_strategy/oplus,ratio_range = [20, 30, 50, 70, 90]
    ddrc_strategy/oplus,temp_range  = [0xFFFFFFCE, 100, 350] = [-50, 100, 350] (0.1°C)
    ddrc_strategy/oplus,temp_type   = 0
    子节点: strategy_ratio_range_{min,low,mid_low,mid,mid_high,high}
            每个含 name + strategy_temp_{cold,cool,normal,warm}
    根下还有 4 个散落的 strategy_temp_* 属性（另有用途，未在本次链路中用到）

    strategy_ratio_range_min/warm (实测 hex 解析, 4 元组):
      (0,    3000, 3060, 0)
      (500,  3000, 3060, 1)
      (1000, 3100, 3150, 2)
      (1000, 3200, 3250, 3)   <- 3250 在此行作为第 3 字段
      (1500, 3300, 3350, 4)   <- 3350 在此行作为第 3 字段
    strategy_ratio_range_mid/warm:
      (0,3000,3060,0) (100,3100,3150,1) (300,3200,3250,2) (600,3300,3350,3)

    （注意：min 档有 6 行、mid 档只有 4 行，与任务书 DT 表一致。）

---

## 7. 不确定 / 待确认

1. **3250 的真实来源未坐实**。本驱动在给定输入下 DDRC 路径给 3350；
   实机 dmesg 也显示 3350 被写入 IC。3250 只作为 warm 表第 4 行的第 3 字段存在。
   需在同一时刻抓 oplus_gauge_get_ddrc_status 的 ratio_value、item 0x1e/0x1f
   与最终 effective_result，才能判定 3250 是哪个 (ratio_region, temp_region) 落点。
   建议 hook：ddrc_strategy_get_data(0x19c4dc) 入参/出参、
   oplus_gauge_update_ddrc_data(0x18cab0) 的 x/y 出参。
2. **item 0x1e 与 deep_dischg_ratio_thr 是否同一值**未直接证实
   （sysfs 名同族，且量级 30 正好落在 ratio_range 边界上）。
3. **4 元组字段语义**：若编号为 (thr, v_lo, v_hi, idx)，get_data 会跳过 v_lo；
   若为 (thr, _, v_lo, v_hi)，才输出两个电压。两种读法的最后一个电压都是 v_hi，
   故 v_hi 为终止电压的结论不受影响，但精确字段名仍存疑。
4. **v1/v2 判定**依赖 strncmp(strategy_name,"ddrc_curve_v2",13)（0x190154）；
   实机 ddrc_strategy_name = "ddrc_curve" => v1。若某些 ROM 该属性为
   "ddrc_curve_v2" 则走 v2（alloc_by_node 布局不同，见 §2），需重新推演。
5. **oplus_gauge_ddrc_temp_thr_update 的函数体未定位**：字符串
   "oplus_gauge_ddrc_temp_thr_update" @ .rodata.str1.1+0xbb111 被
   oplus_gauge_deep_temp_work 0x191bec-0x191c34 引用；dmesg 显示它会动态改写
   温度阈值（±20 步进，例如 thr[2] -> 370）。这可能是 3250/3350 差异的另一个变量。
6. **本次未用 Ghidra 反编译**（时间/token 预算），全部结论来自 LLVM 反汇编逐条阅读；
   §3.4 消费者对两个电压字段的具体 vote 语义（哪个是下限/上限）为推测。


---

# 修订 v2：3250 的可行域与下发时机

> 本节修正 §0/§4 中「驱动实发 3350 ⇒ 前提不成立」的结论。父代理的纠正依据成立：
> dmesg 的 `volt = 3350` 是**模块**（uv2800 adsp_write）发起的写入、驱动只执行并回读；
> 且首次读到 3250 发生在 02:07:08（前一次开机），不在本 dmesg 缓冲区内。
> 因此 3350 是**模块写入后的回读值**，不是驱动 DDRC 的稳态输出。

## V2.1 修正后的表数据（重要：此前 §2/§6/§4 的 DT 表解析有误）

前一版把 DT 的**大端** u32 当小端解析，导致表格错乱。以下为按大端重新解析的**正确**数据
（数据源：真机 `od -t x1` 原始字节，重新逐字节解析）：

每张表是 N 个 4 元组 `(thr, v_lo, v_hi, idx)`，N = 3 / 4 / 5。共 6 ratio 档 × 4 temp 档 = 24 张表：

```
min      /cold   (0,2800,3000,0) (500,2900,3100,1) (1000,3000,3150,2)
min      /cool   (0,3000,3150,0) (500,3000,3150,1) (1000,3100,3250,2)
min      /normal (0,3000,3150,0) (500,3100,3250,1) (1000,3200,3300,2)
min      /warm   (0,3000,3150,0) (500,3100,3250,1) (1000,3200,3300,2)
low      /cold   (0,2800,3000,0) (500,2900,3100,1) (1000,3000,3150,2)
low      /cool   (0,3000,3150,0) (500,3000,3150,1) (1000,3100,3250,2)
low      /normal (0,3000,3150,0) (500,3100,3250,1) (1000,3200,3300,2)
low      /warm   (0,3000,3150,0) (500,3100,3250,1) (1000,3200,3300,2)
mid_low  /cold   (0,2800,3000,0) (400,2900,3100,1) (800,3000,3150,2)
mid_low  /cool   (0,3000,3150,0) (400,3000,3150,1) (800,3100,3250,2)
mid_low  /normal (0,3000,3150,0) (400,3100,3250,1) (800,3200,3300,2)
mid_low  /warm   (0,3000,3150,0) (400,3100,3250,1) (800,3200,3300,2)
mid      /cold   (0,2800,3000,0) (200,2900,3100,1) (400,3000,3150,2) (1000,3100,3250,3)
mid      /cool   (0,3000,3150,0) (200,3000,3150,1) (400,3100,3250,2) (1000,3200,3300,3)
mid      /normal (0,3000,3150,0) (200,3100,3250,1) (400,3200,3300,2) (1000,3300,3370,3)
mid      /warm   (0,3000,3150,0) (200,3100,3250,1) (400,3200,3300,2) (1000,3300,3370,3)
mid_high /cold   (0,2800,3000,0) (60,2900,3100,1) (120,3000,3150,2) (220,3000,3150,3) (1000,3100,3250,4)
mid_high /cool   (0,3000,3150,0) (60,3000,3150,1) (120,3100,3250,2) (220,3200,3300,3) (1000,3200,3300,4)
mid_high /normal (0,3000,3150,0) (60,3100,3250,1) (120,3200,3300,2) (220,3300,3370,3) (1000,3350,3400,4)
mid_high /warm   (0,3000,3150,0) (60,3100,3250,1) (120,3200,3300,2) (220,3300,3370,3) (800,3350,3400,4)
high     /cold   (0,2800,3000,0) (30,2900,3100,1) (60,3000,3150,2) (110,3100,3250,3) (160,3100,3250,4)
high     /cool   (0,3000,3150,0) (30,3000,3150,1) (60,3100,3250,2) (110,3200,3300,3) (160,3200,3300,4)
high     /normal (0,3000,3150,0) (30,3100,3250,1) (60,3200,3300,2) (110,3300,3370,3) (160,3350,3400,4)
high     /warm   (0,3000,3150,0) (30,3100,3250,1) (60,3200,3300,2) (110,3300,3370,3) (160,3350,3400,4)
```

注意：**normal 与 warm 各档逐项相同**（与任务书 §2 的观察一致）；
mid_high/warm 末行 thr 是 **800**（不是 1000），high/cold 末行也是 **160**。

### 行内阈值语义（已证实 = 任务书所说的「计数阈值」语义）

```
语义A「取 thr <= counts 的最后一行」：
  min/warm   + counts=1758 → 末行 (1000,3200,3300,2) → v_hi=3300
  mid/warm   + counts=1758 → 末行 (1000,3300,3370,3) → v_hi=3370
  high/warm  + counts=1758 → 末行 (160,3350,3400,4)  → v_hi=3400
语义B「取 counts < thr 的第一行」：1758 越过全部表 → 全部落在末行，命中 3250 的组合 = 0
```
⇒ **语义A** 成立；语义B 排除。这同时说明：**3250 绝不是 counts≈1758 落在 warm 档的结果**
（warm 档 counts 大时给 3300/3370/3400）。

## V2.2 穷举：counts=1758 下能产出 3250 的全部 (ratio_region, temp_region) 组合

在语义A（`thr <= counts` 取最后一行）下，遍历 24 张表：

```
 min     /cool    row2 (1000,3100,3250,2)   → v_hi=3250   ← 命中
 low     /cool    row2 (1000,3100,3250,2)   → v_hi=3250   ← 命中
 mid_low /cool    row2 ( 800,3100,3250,2)   → v_hi=3250   ← 命中
 mid     /cold    row3 (1000,3100,3250,3)   → v_hi=3250   ← 命中
 mid_high/cold    row4 (1000,3100,3250,4)   → v_hi=3250   ← 命中
 high    /cold    row4 ( 160,3100,3250,4)   → v_hi=3250   ← 命中
```

**结论（已证实）**：恰好 **6 种**组合，**全部是 v_hi**，且只需 **temp_region ∈ {cool, cold}**：
- cool 需 ratio_region ∈ **{0(min), 1(low), 2(mid_low)}**
- cold 需 ratio_region ∈ **{3(mid), 4(mid_high), 5(high)}**

**不是只有 min/cool、min/cold 两种。** 但**共同必要条件**是：
> **temp_region 必须是 cool 或 cold**（即索引 1 或 0）。
> 若 temp_region ∈ {normal(2), warm(3)}，无论 ratio_region 取 0..5、counts 取多大，
> **都不可能在 3250 上**（normal/warm 档的值域里 3250 只作为 v_lo 出现在别的行，
> 且在 counts>=1000 时全部被越过后落到 3300/3370/3400）。

### V2.2b 「3250 作为 v_hi」的完整命中区间（不受 counts=1758 限制）

```
 min     /cool   [1000, inf)      low     /cool   [1000, inf)      mid_low /cool   [800, inf)
 min     /normal [ 500, 1000)     low     /normal [ 500, 1000)     mid_low /normal [400, 800)
 min     /warm   [ 500, 1000)     low     /warm   [ 500, 1000)     mid_low /warm   [400, 800)
 mid     /cold   [1000, inf)      mid     /cool   [400, 1000)      mid     /normal [200, 400)
 mid     /warm   [200, 400)       mid_high/cold   [1000, inf)      mid_high/cool   [120, 220)
 mid_high/normal [ 60, 120)       mid_high/warm   [ 60, 120)      high    /cold   [110, 160) 和 [160, inf)
 high    /cool   [ 60, 110)       high    /normal [ 30,  60)      high    /warm   [ 30,  60)
```
⇒ 1758 只落在三个 `[.., inf)` 区间（min/cool、low/cool、mid_low/cool、mid/cold、
mid_high/cold、high/cold 这几行的**末行**），这也解释了为何 6 种组合都要求 cool/cold。

## V2.3 temp_region 对应的温度区间（已证实）

`oplus_gauge_ddrc_get_temp_region` 0x18c7f0 的循环（0x18c848）：

```
18c83c:  ldr  x9, [x20, #0x1020]   ; 阈值数组（动态！见 V2.6）
18c848:  ldr  w10, [x9, x19, lsl #2]
18c84c:  cmp  w0, w10
18c850:  b.lt 0x18c864            ; T < thr[i] → region = i
                                    ; 全部未命中 → region = n
```
初始阈值数组 = `oplus,temp_range` = `[0xFFFFFFCE, 100, 350]` = **[-50, 100, 350]**
（单位 0.1°C；DT 实测，任务书 §2 的 [-50,100,350] 正确）。故：

| temp_region | 温度区间（初始阈值） | 名称 | 本机 35.6°C |
|---|---|---|---|
| 0 | **T < -5.0 °C** | cold | 否 |
| 1 | **-5.0 °C ≤ T < 10.0 °C** | cool | 否 |
| 2 | **10.0 °C ≤ T < 35.0 °C** | normal | 否（35.6 > 35.0） |
| 3 | **T ≥ 35.0 °C** | warm | **是** |

⇒ 本机 35.6°C 得到 **temp_region = 3 (warm)**，**在 3250 的可行域之外**。

### 温度来源与「失败回退」（关键，已证实）

```
oplus_gauge_get_deep_dischg_temperature 0x18c700:
   w1 = 0 → oplus_mms_get_item_data(ic[0x30], 6, &t)   ; 0x18c73c  主 gauge 温度
   w1 = 1 → oplus_mms_get_item_data(ic[0x48], 0xe, &t) ; 0x18c780  副/shell 温度 (w3=0)
   两者都失败 → 0x18c7a0: mov w0, #-0xc8  = -200  ⇒ **返回 -200（= -20.0 °C）**
```
**-20.0 °C < -5.0 °C ⇒ temp_region = 0 (cold)。**
⇒ **任何一次温度读取失败（或温度尚未就绪）都会把 temp_region 打成 cold**，
配合 ratio_region ∈ {3,4,5} 即可产出 3250。这是 3250 在「高温实机」上出现的最合理机制。

而 `temp_type == 1`（shell temp，DT 实测 temp_type = **0**，故本机不走这条）
的取值分支 `w3 = 0` 是 **非强制读取**（`oplus_mms_get_item_data(..., w3=0)`），
失败概率更高 —— 是 cool 档（-5.0~10.0 °C）的一个候选来源。

## V2.4 ratio_region 条件（已证实）

`oplus_gauge_get_ratio_value` 0x18c87c 归约路径：
- `temp_type==0` → 值来自 `ic+0xfdc`（= `deep_dischg_ratio_thr`，本机 = 30），
  出口变量 `ic+0xfe0`
- `temp_type==1` → 值来自 `ic+0xfe0`，出口 `ic+0xfe8`
- 内部用 `oplus_gauge_get_deep_dischg_count` 与 `oplus_gauge_get_dec_cv_soh`
  做一次整数除法归约（0x18c9cc 附近 `sdiv`），失败时兜底 100

`ddrc_strategy_init` 0x19c054 的逐级比较（0x19c0b4 起，见 §5.3）：

```
   ratio < 20  → 0        ← 严格小于，**不含等号**
   20 <= ratio < 30  → 1
   30 <= ratio < 50  → 2
   50 <= ratio < 70  → 3
   70 <= ratio < 90  → 4
   ratio >= 90 → 5
```
⇒ **边界含下不含上**（`b.hs` = 无符号 >= 继续，故等号归**上**一档）。
本机 ratio=30 ⇒ **ratio_region = 2 (mid_low? 注意)**：
严格说 30 落 `20<=30<30` 为假 → 继续；`30<=30<50` 为真 ⇒ **ratio_region = 2**。

> 重要：ratio_region = 2 对应 DT 子节点 `strategy_ratio_range_mid_low`
> （子节点枚举顺序 = min, low, mid_low, mid, mid_high, high，见 §6）。
> 故本机 (ratio_region, temp_region) = **(2, 3) = mid_low/warm**
> = `(0,3000,3150,0) (400,3100,3250,1) (800,3200,3300,2)`
> counts=1758 → 末行 → **v_hi = 3300**。

**这修正了 §4/§6 的数值**：本机在「无温度读取失败」时稳态应为 **3300**（不是 3350、
也不是 3250）。若 ratio_region 落到 3(mid)/warm，则末行 v_hi = 3370。

## V2.5 下发时机（回答 Q4；核心新证据）

### (a) DDRC 计算自带 1250 ms 自重启周期（已证实）

`oplus_gauge_deep_temp_work` 0x19192c 尾部（0x191d98–0x191dac）：

```
191d98:  adrp x8, 0x191000
191d9c:  mov  w0, #0x20               ; CPU 0
191da0:  mov  x2, x19                ; &dev->deep_temp_work
191da4:  ldr  x1, [x8]               ; system_wq
191da8:  mov  w3, #0x4e2             ; **= 1250 (jiffies @HZ=250 ⇒ 5 s；见注)**
191dac:  bl   queue_delayed_work_on
```
（注意 `queue_delayed_work_on` 的 delay 参数单位是 **jiffies**。C16.0.5.701 内核 HZ 需确认：
若 HZ=100 则 12.5 s；HZ=250 则 5.0 s；HZ=300 则 ≈4.17 s。
**该 HZ 未在本次反汇编中判定，标为推测**——但无论如何都是**秒级周期**，
而非一次性。）

⇒ `oplus_gauge_deep_temp_work` → `oplus_gauge_get_ddrc_status` 是**秒级常驻周期**，
从 probe 注册后即持续运行。**不存在「开机后数分钟才首次下发」的周期延迟**。

### (b) DDRC vote 的下发目标：**不是**模块 hook 的那个 op（已证实，重要）

`oplus_gauge_get_ddrc_status` 只对三个 voter 投票（字符串已解析）：
`DEEP_COUNT_VOTER`、`SUB_DEEP_COUNT_VOTER`、`SUPER_ENDURANCE_MODE_VOTER`，
并写 track 日志
`$$track_reason@@vote$$temp_p@@%d$$temp_n@@%d$$ratio_p@@%d$$ratio_n@@%d$$vstep@@%d$$vterm_final@@%d$$term_now@@%d$$index@@%d`
（0x18cee4）—— `vterm_final` 才是最终终止电压，`vstep` 是 step，`index` 是 idx。

而把它写进 IC 的是另外两条路径，**使用完全不同的 op id**：

| 函数 | op id | 作用 |
|---|---|---|
| `oplus_mms_gauge_set_deep_term_volt` 0x18a9d0 | **0x1c8** | IC 侧「深度终止电压」写/读（`oplus_chg_ic_debug_get_func` @0x18aae8/0x18abe0） |
| `oplus_mms_gauge_sili_term_volt_effect_check_work` 0x18f668 | **0x1d1** (0x18f6e8) + 调 `oplus_mms_gauge_set_deep_term_volt` (0x18f794) | 效果校验后回写 |
| `oplus_mms_gauge_set_deep_term_volt_work` 0x193a94 | 调 0x18a9d0 写；再用 **0x1ce** 回读 (0x193afc) | 周期回写 + 回读校验 |
| `oplus_set_deep_term_volt` 0xc9240 / `oplus_fg_*` 0x1e4b68/0x1e4ca4 | **0x1ce** | **ADSP** 侧深度终止电压（dmesg 打印这条） |
| `oplus_gauge_get_ddrc_status` 0x18cd28 读现值 | **0x1ce** (@0x18ce58) | 读 **ADSP** 侧现值用于 vote 比较 |

⇒ **DDRC 计算出来的值（vterm_final）走的是 0x1c8 写入器；模块 hook 的 `adsp_read` 读的是 0x1ce。**
二者是**不同的 IC 寄存器 / 不同的 op**。这解释了为什么「模块首次读到 3250」与
「驱动 DDRC 算出的 vterm_final」可以长期不一致 —— 它们本来就不是同一个数。

### (c) 首次读到 3250 的可能来源（推测，按可能性排序）

1. **IC 上电默认值 / 前一次开机残留**：0x1ce（ADSP 深度终止电压）在驱动首次写入前
   保留 IC/ADSP 侧的持久值。模块在 02:07:08（前一次开机早期）读到的 3250
   很可能是**上一次开机写入后留下的值**，或是 IC 固件默认值。
   本 dmesg（uptime 685 s 之后）里 0x1ce 的值是 3350，正是**模块自己写进去的**。
2. **温度读取失败 → temp_region=cold（V2.3）**：会走 `mid/cold` 等表给出 3250，
   但那只影响 **0x1c8** 的 vterm_final，不直接改 0x1ce。
3. **gauge 早期未就绪**：`oplus_gauge_get_deep_dischg_temperature` 与
   `oplus_gauge_get_ratio_value` 都会在失败时回退（-200 / 100），
   早期窗口内 vterm_final 会短时落在 cold/别的档，但同样是 0x1c8 侧。

⇒ **Q4 的直接回答**：
> 更符合代码路径的是 **(2)「上电早期 gauge 寄存器 = 3250」这一侧**，但**不是**因为
> 「ddrc vote 尚未下发」——DDRC vote 是秒级常驻、早就下发了；而是因为
> **DDRC vote 走 0x1c8 写入器，模块读的 0x1ce 是另一条链**（ADSP 侧），
> 在模块自己写入之前，0x1ce 的值由 IC/ADSP 侧的持久状态决定，与驱动 DDRC 无关。
> 「驱动稳态输出 = 3350」这个说法本身也不成立：驱动 DDRC 在本机 (ratio_region=2,
> temp_region=3) 下算出的 vterm_final 是 **3300**（mid_low/warm 末行），
> 而 3350 是**模块写进 0x1ce 的值**。

**是否存在「开机后数分钟才首次下发」的可能？** 就 DDRC 计算与 0x1c8 写入而言：**不太可能**
（1250-jiffy 自重启周期，probe 后即开始）。就 **0x1ce** 而言：**可能**，
因为 0x1ce 的写入由 gauge 侧的工作（`oplus_mms_gauge_set_deep_term_volt_work`）
或外部（模块）驱动，其首次下发时机取决于这些 work 的调度与 `batt_full`/`online` 等
事件门槛，本次未逐条坐实（标为**推测**）。

## V2.6 `oplus_gauge_ddrc_temp_thr_update` 能改哪些边界、范围多大（回答 Q3）

**已证实**：该字符串（`.rodata.str1.1+0xbb111`）被 `oplus_gauge_deep_temp_work`
本身引用（0x191bec / 0x191bf0 / 0x191c30 / 0x191c34），日志格式串为
`"...now=%d, pre=%d, p[%d]update thr[%d] to %d"`（dmesg 实测输出见 §5.4）。
所以**阈值更新逻辑就在 `oplus_gauge_deep_temp_work` 内**，操作对象是
`ic+0x1020` 指向的**温度阈值数组**（即 `oplus,temp_range` 的运行时副本）：

```
191b34:  ldr  x8, [x19, #0x5c0]     ; 源数组 = oplus,temp_range 副本
191b38:  ubfiz x9, x24, #2, #0x20   ; x9 = temp_region*4
191b3c:  ldr  x10, [x19, #0x5a8]    ; 目标数组 = 运行时阈值 (即 ic+0x1020)
191b40:  ldr  w8, [x8, x9]
191b44:  add  w8, w8, #0x14         ; **+20 (0.1°C ⇒ +2.0 °C)**
191b48:  str  w8, [x10, x9]         ; 写回运行时阈值
...
191b9c:  sbfiz x10, x9, #2, #0x20
191ba4:  ldr  w8, [x8, x10]
191ba8:  sub  w8, w8, #0x14         ; **-20 ⇒ -2.0 °C**
191bac:  str  w8, [x11, x10]
```

- **能改**：温度阈值数组（`temp_region` 的边界），步进 **±20 = ±2.0 °C**；
  数组元素数由 `oplus,temp_range` 长度决定（本机 3 个：-5.0 / 10.0 / 35.0 °C）。
- **不能改**：`oplus,ratio_range`（[20,30,50,70,90]）—— 全反汇编中
  `ic+0x258..0x268` 只有读、没有写；ratio 边界是**静态**的。
- **改动效果（dmesg 实证）**：`p[3]update thr[2] to 370` = 把第 3 个阈值
  (35.0 °C) 改成 **37.0 °C**。此后 35.6 °C < 37.0 ⇒ temp_region 由 3(warm)
  变成 **2(normal)**。**这正好解释了「同一台机、同一温度，档位可能跳到 normal」**。
  注意 normal 与 warm 各档逐项相同（V2.1），所以这次改动**不改变电压结果**；
  但它证明了运行时阈值可变。

**是否存在某种初始/上电状态下 temp_region 被算成 cool 的可能？**
**存在，且路径明确（已证实）**：
1. 温度读取失败 → `oplus_gauge_get_deep_dischg_temperature` 返回 **-200 (-20.0 °C)**
   ⇒ temp_region = **0 (cold)**（不是 cool，但同属 3250 可行域）。
2. 若 `temp_type == 1`（走 shell temp，非强制读取，失败概率更高），
   且 shell 温返回 0~99（0.0~9.9 °C）⇒ temp_region = **1 (cool)**。
   本机 DT `oplus,temp_type = 0`，所以本机主要靠路径 1。
3. `deep_temp_work` 自身的 ±2.0 °C 阈值调整**只动边界**，不会把 35.6 °C 打成 cool。

## V2.7 修订后的结论表

| 项 | v1 结论 | **v2 修订** |
|---|---|---|
| 本机 ratio_region | 2（"mid"） | 2，但对应子节点名是 **mid_low**（枚举顺序 min,low,mid_low,mid,mid_high,high） |
| 本机 temp_region | 3 (warm) | 3 (warm)（未变；除非运行期阈值被改成 370 ⇒ 2/normal） |
| 本机稳态 v_hi | 3350 | **3300**（mid_low/warm 末行 (800,3200,3300,2)）★ 修正 |
| 3350 的来源 | 「驱动实发」 | **模块（uv2800）写入后驱动回读**；非驱动 DDRC 输出 ★ 修正 |
| 3250 来源 | 未坐实 | **temp_region ∈ {cold,cool} 且 ratio_region 配对**；6 种组合（V2.2） |
| 下发周期 | 未分析 | `deep_temp_work` 每 **1250 jiffies** 自重启 ⇒ 秒级常驻 |
| 与模块的关系 | 同一条链 | **不同 op**：DDRC→0x1c8；模块 hook→0x1ce ★ 修正 |

## V2.8 已证实 / 推测 一览（v2 新增部分）

**已证实**
- 24 张表的正确内容与 4 元组语义（大端解析，原始字节复算）。
- 行内阈值语义 = 「取 thr <= counts 的最后一行」（语义A）；语义B 命中 0 种。
- counts=1758 下产出 3250 的**全部**组合 = 6 种，**全部要求 temp_region ∈ {cool, cold}**。
- temp_region 阈值数组 = [-50,100,350]（0.1°C）⇒ cold< -5.0 / cool< 10.0 / normal< 35.0 / warm ≥ 35.0。
- 温度读取失败回退 **-200 (-20.0 °C)** ⇒ temp_region = cold。
- ratio_region 边界**含下不含上**（严格小于）。
- `deep_temp_work` 每 1250 单位自重启（`mov w3,#0x4e2` @0x191da8）。
- 阈值更新逻辑在 `oplus_gauge_deep_temp_work` 内，步进 **±20 (0.1°C) = ±2.0 °C**；
  只能改温度阈值，改不了 ratio_range。
- 写入器 op 映射：0x1c8 = `oplus_mms_gauge_set_deep_term_volt`；
  0x1ce = ADSP 侧（`oplus_set_deep_term_volt` / `oplus_fg_*` / DDRC 读现值）；
  0x1d1 = effect check；0x1d2 = SILI alg term volt。
- DDRC 计算结果经 `vterm_final` 进 track 日志，投票给 DEEP_COUNT / SUB_DEEP_COUNT /
  SUPER_ENDURANCE_MODE 三个 voter。

**推测**
- `queue_delayed_work_on` 的 1250 单位换算成秒取决于 CONFIG_HZ（未判定）：HZ=250 ⇒ 5.0 s。
- 0x1ce 通道「首次下发」的确切时机（哪个 work 先跑、是否有 batt_full/online 门槛）未坐实。
- `oplus_gauge_get_ratio_value` 中 `ic+0xfdc` 是否**就是** sysfs `deep_dischg_ratio_thr`
  （值同为 30，高度可疑，但未直接证实）。
- 首次读到 3250 时具体是「IC/ADSP 持久残留」还是「温度失败致 cold」造成，未定案；
  建议在同一时刻同时抓 `ic+0x1020` 温度阈值、`oplus_gauge_get_deep_dischg_temperature`
  返回值、`ratio_value`、`vterm_final`（track 日志）与 0x1c8/0x1ce 两侧寄存器值。

---

# 修订 v3：节点归属确认 + 用 p770 表重算（**取代 v2 的表数据与穷举**）

> 父代理指出 v2 表数据与其核对不符 —— **父代理正确**。原因：真机 DT 里存在**两棵**子树，
> 我 v2（以及 v1）抓的是**顶层** /soc/oplus,mms_gauge/ddrc_strategy，
> 而驱动实际使用的是 **/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy**。
> 顶层那棵是另一份（行数与数值都不同），不是驱动读的那份。

## V3.1 节点是怎么拿到的（已证实）

### 第 1 步：base 节点 = mms_gauge 节点，然后按 battery_type 下沉一层

oplus_gauge_parse_deep_spec 0x18f7f8:

    18f82c:  ldr  x8, [x0]                 ; x8 = *(mms)
    18f83c:  ldr  x20, [x8, #0x300]        ; x20 = dev->of_node (即 /soc/oplus,mms_gauge)
    18f834:  sub  x0, x29, #0x38           ; 16 字节栈缓冲
    18f840:  stp  xzr, xzr, [x29, #-0x38]  ; 清零
    18f844:  bl   oplus_gauge_get_battery_type_str    ; 填充字符串
    18f848:  cbnz w0, 0x18f860             ; 失败则不平移
    18f84c:  sub  x1, x29, #0x38           ; x1 = 类型字符串
    18f850:  mov  x0, x20                  ; x0 = /soc/oplus,mms_gauge
    18f854:  bl   of_get_child_by_name     ; ★ 按名字取子节点
    18f858:  cmp  x0, #0
    18f85c:  csel x20, x20, x0, eq         ; 子节点存在则用它，否则回退顶层
    18f860:  ...                            ; x20 = /soc/oplus,mms_gauge/silicon_p_770

随后所有 deep_spec,* 属性（0x18f860 deep_spec,term_coeff、0x18f948 count_thr、
0x18f978 spare_power_term_voltage、0x18f9a8 vbat_soc、0x18f9dc/0x18fa0c/0x18fa60…）
都是**以 x20（= p770 节点）为 base** 读的。

### 第 2 步：battery_type 字符串怎么来的

oplus_gauge_get_battery_type_str 0x18e0f0，三条来源，按序：

    18e118: of_find_node_opts_by_path("/soc/oplus_chg_core")
    18e130: of_find_property(node, "oplus,battery_type_by_smem")
            -> qcom_smem_get(...) -> snprintf(buf, 0x10, "%s", smem+0x10)   ; 18e16c
      或
    18e174: of_find_property(node, "oplus,battery_type_by_cmdline")
    18e270: of_find_node_opts_by_path("/chosen")
    18e284: of_get_property(chosen, "bat_type")
      或
    18e198/18e1a0: strstr(cmdline, "battery_type=") -> scnprintf(buf, 0x10, "%s", p+0xd)

本机结果 = **"silicon_p_770"**（与 /sys/class/oplus_chg/battery/battery_type 一致）。

### 第 3 步：ddrc_strategy 节点 = 同一个 x21 的子节点

    18ff20:  ldr  x21, [x9, #0x300]         ; x21 = /soc/oplus,mms_gauge
    18ff24:  bl   oplus_gauge_get_battery_type_str
    18ff34:  bl   of_get_child_by_name      ; ★ 同样按 battery_type 下沉
    18ff3c:  csel x21, x21, x0, eq          ; x21 = /soc/oplus,mms_gauge/silicon_p_770
    18ff40:  mov  x0, x21
    18ff44:  mov  x1, xzr
    18ff4c:  bl   of_get_next_child         ; ★ 遍历 x21 的子节点
    18ff78:  ldr  x0, [x22]                 ; 子节点 name
    18ff80:  mov  w2, #0xd
    18ff84:  bl   strncmp                   ; 与 13 字符串前缀比较 -> 计数 strategy_ratio_range_*
    ...
    190248:  mov  x0, x21                  ; ★ 同一个 x21 (p770)
    190240:  x1 = "ddrc_strategy"
    19024c:  bl   of_get_child_by_name      ; -> /soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy
    190254:  mov  x22, x0
    190258:  ldr  x0, [x19, #0x1968]         ; strategy 描述符 (寄存器选出的 v1/v2 desc)
    19025c:  mov  x1, x22
    190260:  bl   oplus_chg_strategy_alloc_by_node   ; ★ 传进去的就是 p770/ddrc_strategy

**回答 Q1（已证实）**：
- 是 **/soc/oplus,mms_gauge/silicon_p_770/ddrc_strategy**（电池子节点），**不是顶层**。
- 获取方式：**of_get_child_by_name**（两次）—— 不是 of_find_node_by_name，
  也不是 of_find_compatible_node；是**从 dev->of_node (mms_gauge) 出发、
  用 battery_type 字符串作为子节点名**逐层下沉。
- 调用点：下沉 @ **0x18f854** 与 **0x18ff34**；策略节点 @ **0x19024c**；
  交给 oplus_chg_strategy_alloc_by_node @ **0x190260**（该描述符的 alloc_by_node 即
  **ddrc_strategy_alloc_by_node 0x19b7d0**）。

**回答 Q2（已证实）**：**是**，完全依赖 battery_type。
battery_type = silicon_p_770 ⇒ of_get_child_by_name(mms_gauge, "silicon_p_770")
命中 ⇒ 用 p770 子树。若该子节点不存在则 csel 回退顶层（0x18f85c / 0x18ff3c），
此时才会用到顶层那份（行数不同的）表。

**回答 Q3（已证实）**：**对，与节点选择无关**。
ic+0x1020 的温度阈值数组、以及 ic+0x258..0x268（ratio_range，只读）
都是**运行期私有结构**里的字段，由 DT 值**拷贝**而来；节点选择只决定**值从哪棵子树读**。
两者是「数据来源」与「数据存放/比较」的关系，互不干涉。

## V3.2 p770 子树 —— 24 张正确表（真机 od 原始字节，大端解析）

    min      /cold   (0,2800,3000,0) (400,2900,3050,1) (800,3000,3060,2) (1200,3100,3150,3) (1600,3200,3250,4) (2000,3300,3350,5)
    min      /cool   (0,3000,3060,0) (15,3000,3060,1) (500,3000,3060,2) (1000,3100,3150,3) (1500,3200,3250,4) (2000,3300,3350,5)
    min      /normal (0,3000,3060,0) (15,3000,3060,1) (500,3100,3150,2) (1000,3200,3250,3) (1500,3300,3350,4)
    min      /warm   (0,3000,3060,0) (15,3000,3060,1) (500,3100,3150,2) (1000,3200,3250,3) (1500,3300,3350,4)
    low      /cold   (0,2800,3000,0) (300,2900,3050,1) (600,3000,3060,2) (900,3100,3150,3) (1200,3200,3250,4) (1600,3300,3350,5)
    low      /cool   (0,3000,3060,0) (15,3000,3060,1) (400,3000,3060,2) (800,3100,3150,3) (1200,3200,3250,4) (1600,3300,3350,5)
    low      /normal (0,3000,3060,0) (15,3000,3060,1) (400,3100,3150,2) (800,3200,3250,3) (1200,3300,3350,4)
    low      /warm   (0,3000,3060,0) (15,3000,3060,1) (400,3100,3150,2) (800,3200,3250,3) (1200,3300,3350,4)
    mid_low  /cold   (0,2800,3000,0) (200,2900,3050,1) (400,3000,3060,2) (600,3100,3150,3) (900,3200,3250,4) (1200,3300,3350,5)
    mid_low  /cool   (0,3000,3060,0) (15,3000,3060,1) (300,3000,3060,2) (600,3100,3150,3) (900,3200,3250,4) (1200,3300,3350,5)
    mid_low  /normal (0,3000,3060,0) (15,3000,3060,1) (300,3100,3150,2) (600,3200,3250,3) (900,3300,3350,4)
    mid_low  /warm   (0,3000,3060,0) (15,3000,3060,1) (300,3100,3150,2) (600,3200,3250,3) (900,3300,3350,4)
    mid      /cold   (0,2800,3000,0) (100,2900,3050,1) (300,3000,3060,2) (500,3100,3150,3) (700,3200,3250,4) (900,3300,3350,5)
    mid      /cool   (0,3000,3060,0) (100,3000,3060,1) (300,3100,3150,2) (600,3200,3250,3) (900,3300,3350,4)
    mid      /normal (0,3000,3060,0) (100,3100,3150,1) (300,3200,3250,2) (600,3300,3350,3)
    mid      /warm   (0,3000,3060,0) (100,3100,3150,1) (300,3200,3250,2) (600,3300,3350,3)
    mid_high /cold   (0,2800,3000,0) (50,2900,3050,1) (100,3000,3060,2) (150,3100,3150,3) (300,3200,3250,4) (500,3300,3350,5)
    mid_high /cool   (0,3000,3060,0) (50,3000,3060,1) (100,3100,3150,2) (150,3200,3250,3) (300,3300,3350,4)
    mid_high /normal (0,3000,3060,0) (50,3100,3150,1) (100,3200,3250,2) (150,3300,3350,3)
    mid_high /warm   (0,3000,3060,0) (50,3100,3150,1) (100,3200,3250,2) (150,3300,3350,3)
    high     /cold   (0,2800,3000,0) (50,2900,3050,1) (100,3000,3060,2) (150,3100,3150,3) (300,3200,3250,4) (500,3300,3350,5)
    high     /cool   (0,3000,3060,0) (50,3000,3060,1) (100,3100,3150,2) (150,3200,3250,3) (300,3300,3350,4)
    high     /normal (0,3000,3060,0) (50,3100,3150,1) (100,3200,3250,2) (150,3300,3350,3)
    high     /warm   (0,3000,3060,0) (50,3100,3150,1) (100,3200,3250,2) (150,3300,3350,3)

**这与任务书 §3 列出的 DT 数据逐项完全一致**（6/5/4 行分布、以及
normal 与 warm 逐项相同）—— 这本身也佐证了驱动读的是 p770 子树。

## V3.3 counts=1758 重算（语义A：取 thr<=counts 的最后一行）

| 表 | 落点 | v_hi |
|---|---|---|
| **min/cold** | (1600,3200,**3250**,4) | **3250** |
| **min/cool** | (1500,3200,**3250**,4) | **3250** |
| min/normal | (1500,3300,3350,4) | 3350 |
| min/warm | (1500,3300,3350,4) | 3350 |
| low/cold | (1600,3300,3350,5) | 3350 |
| low/cool | (1600,3300,3350,5) | 3350 |
| low/normal | (1200,3300,3350,4) | 3350 |
| low/warm | (1200,3300,3350,4) | 3350 |
| mid_low/cold | (1200,3300,3350,5) | 3350 |
| mid_low/cool | (1200,3300,3350,5) | 3350 |
| mid_low/normal | (900,3300,3350,4) | 3350 |
| mid_low/warm | (900,3300,3350,4) | 3350 |
| mid/cold | (900,3300,3350,5) | 3350 |
| mid/cool | (900,3300,3350,4) | 3350 |
| mid/normal | (600,3300,3350,3) | 3350 |
| mid/warm | (600,3300,3350,3) | 3350 |
| mid_high/cold | (500,3300,3350,5) | 3350 |
| mid_high/cool | (300,3300,3350,4) | 3350 |
| mid_high/normal | (150,3300,3350,3) | 3350 |
| mid_high/warm | (150,3300,3350,3) | 3350 |
| high/cold | (500,3300,3350,5) | 3350 |
| high/cool | (300,3300,3350,4) | 3350 |
| high/normal | (150,3300,3350,3) | 3350 |
| high/warm | (150,3300,3350,3) | 3350 |

### 穷举结论（counts=1758）

- **v_hi = 3250：只有 2 组** —— **min/cold** 与 **min/cool**（父代理的猜测正确）。
- **v_hi = 3300：0 组**（3300 在 p770 表中只作为 v_lo 出现，从不作为 v_hi）。
- **v_hi = 3350：22 组**（其余全部）。

=> 完全符合「模块 DT 走查得 3350」（22/24 组合给 3350，是压倒性多数）。

### 产生 3250 的条件（已证实）

- **必须 ratio_region = 0**（= strategy_ratio_range_min）；
  即 ratio < ratio_range[0] = 20，**严格小于、不含等号**（见 §5.3 的 b.hs）。
- **必须 temp_region ∈ {0 (cold), 1 (cool)}**：
  T < -5.0 °C（cold）或 -5.0 <= T < 10.0 °C（cool）。
- **counts 条件**：cold 需 counts >= 1600（下一条 thr=2000）；
  cool 需 1500 <= counts < 2000。**1758 同时满足两者**。

### 反推本机 3250 的必要输入（推测，但约束很强）

本机 deep_dischg_ratio_thr = 30 若直接参与比较，则 ratio_region = 2（30 落
20<=30<30 假 -> 30<=30<50 真），**给不出 3250**。故 3250 要求：
- ratio_region = 0 <= ratio < 20（与 sysfs 的 30 不符），**且**
- temp_region = 0 或 1 <= 需要**温度读取失败/未就绪**：
  oplus_gauge_get_deep_dischg_temperature 0x18c700 失败时返回 **-200（=-20.0 °C）**
  => **temp_region = 0 (cold)** —— 这一条最容易发生，且与本机 35.6 °C 无关。
- 另注意 deep_spec,count_cali = 0、oplus,count_cali 为 0 时算法不修正 counts。

=> **3250 = (ratio_region=0, temp_region=0 即 cold) 或 (ratio_region=0, temp_region=1 即 cool)**。
cold 路径（温度读失败 -> -20.0 °C）是最可能的解释。

## V3.4 对 v1/v2 的更正清单

| 旧说法 | v3 更正 |
|---|---|
| v1 §2/§4/§6 的 DT 表 | 作废（字节序错 + 抓错子树） |
| v2 §V2.1 的 24 张表 | 作废，改用 V3.2 的 p770 表 |
| 3250 有 6 种组合 | **错，只有 2 种**：min/cold、min/cool |
| v_hi=3300 @counts=1758 | **错，0 组**（3300 从不作 v_hi） |
| 本机 ratio_region=2 -> mid_low/warm -> 3300 | **作废**（那是顶层表的结论） |
| 节点选择 | **新增已证实**：p770 子树（of_get_child_by_name ×2） |
| temp/ratio 条件、ic+0x1020、op 映射、1250-jiffies 周期 | **仍然有效**（与节点选择无关） |
