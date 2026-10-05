# RE-B：跨驱动版本比对 —— 3350 vs 3250 能否由驱动版本解释

生成：RE-B 子代理（跨版本比对，不做深度逆向）
输入：`<EXTERNAL>/厂商驱动与固件/versions/*/oplus_chg_v2.ko`（六份）
方法：pyelftools 取符号表 + capstone 5.0.7 反汇编 + 模块重定位表（SHT_RELA）解析 callee 与被引用字符串；所有结论均由脚本产出，脚本在 `逆向脚本与产物/scripts/re_b_*.py`

---

## 0. 结论摘要（先看这里）

| 问题 | 结论 | 置信度 |
|---|---|---|
| 六份驱动的 md5 是否与任务书一致 | 一致，逐份核对 | 高 |
| 3350 vs 3250 的驱动侧"表/常量"是否随版本变化 | **不变化**：六份驱动内部**都不存在** DDRC 阈值表——逐行 4 元组 `(阈值,v_lo,v_hi,idx)` 0 命中，且 u32 常量 3250 与 3350 各 0 命中（仅个别无关函数里出现同值立即数，见 §3.2），表 100% 来自 DT | **高** |
| 驱动版本是否可能解释 3350→3250 | **不能作为解释**（表、行数校验、选行循环、取值字段在 6.6.66 与 6.6.89 上完全等价）；**唯一未排除项**是 6.6.89 上 `oplus_gauge_get_ratio_value` 新增的 SOH 补偿分支，它对**同一份 counts/cc**可能算出不同 ratio，从而改变选行（§8/§9 已定量） | 中高 |
| 差异更可能的原因 | **运行时输入**：3350 与 3250 在 DT 表内是**相邻两行的不同字段**（如 normal/warm 表第 4 行 v_hi=3250、第 5 行 v_hi=3350），而选哪一行只由实时 ratio 决定；ratio = 10×counts/cc（cc=库仑计）；**选行的比较对象就是 cc 本身**（§10），输入都是实时量 | 中高 |

**一句话**：驱动侧"阈值表 + 阈值立即数 + 温度/ratio 取值来源"在 6.6.66 与 6.6.89 上**语义等价**（只差结构体偏移与日志行号），且六份驱动里根本没有硬编码的 3250/3350；因此 3350 vs 3250 **不能由"表被换掉"解释**，第二批（§7–§11）已把这条线索做完，并**修正了本节的一处措辞**：选行的比较对象不是 `counts` 也不是 `ratio`，而是 `deep_spec.cc`（库仑计 `GAUGE_ITEM_CC`）；ratio 的除数也是 `cc`，**不是电压**。详见 §8 与 §10。

---

## 1. 符号地址 / 大小对照表

`llvm-objdump` 不可用于本表（见 §5 说明），下表由 pyelftools 直接读 `.symtab` 得到，格式 `地址 / 字节大小`，地址为节内相对地址（这些 .ko 的所有节 VMA 均为 0，故地址可比"节内偏移"，跨版本不可直接比较）。

| 符号 | C15.0.0.126<br>6.6.30<br>2895f82d | C15.0.0.821<br>6.6.30<br>7aaf68e1 | C15.0.0.861<br>6.6.66<br>715531c3 | C16.0.0.212<br>6.6.89<br>c75d23e6 | C16.0.5.701<br>6.6.89<br>**c6fedbc8** | C17.0.0.100<br>6.6.118<br>891cb06b |
|---|---|---|---|---|---|---|
| `ddrc_strategy_alloc_by_node` | 0x1183c8 / 1868 | 0x12cdf4 / 1868 | 0x12e68c / 1868 | 0x1715b8 / **1964** | 0x19b7d0 / **1964** | 0x1cc628 / **1964** |
| `ddrc_strategy_init` | 0x118bec / 1168 | 0x12d618 / 1168 | 0x12eeb0 / 1168 | 0x171e3c / **1156** | 0x19c054 / **1156** | 0x1cceac / **1156** |
| `ddrc_strategy_get_data` | 0x119080 / 152 | 0x12daac / 152 | 0x12f344 / 152 | 0x1722c4 / 152 | 0x19c4dc / 152 | 0x1cd334 / 152 |
| `ddrc_strategy_release` | 0x118b18 / 208 | 0x12d544 / 208 | 0x12eddc / 208 | 0x171d68 / 208 | 0x19bf80 / 208 | 0x1ccdd8 / 208 |
| `oplus_get_deep_term_volt` | 0x8f4d8 / 504 | 0xa11d4 / 504 | 0xa1e18 / 504 | 0xb191c / **516** | 0xcb8a0 / **516** | 0xe798c / **516** |
| `oplus_set_deep_term_volt` | 0x8d838 / 1472 | 0x9ec30 / 1472 | 0x9f874 / 1472 | 0xaf2cc / **1488** | 0xc9240 / **1488** | 0xe5244 / **1488** |
| `oplus_gauge_get_sili_ic_alg_term_volt` | 0x8cbf0 / 112 | 0x9dfe8 / 112 | 0x9ec2c / 112 | 0xae65c / 112 | 0xc85c8 / 112 | 0xe45cc / 112 |
| `oplus_mms_gauge_get_sili_ic_alg_term_volt` | 0x10e8c4 / 608 | 0x122c3c / 608 | 0x1244d4 / 608 | 0x165048 / 608 | 0x18e760 / 608 | 0x1bc700 / 608 |
| `get_three_level_term_volt_show` | **该版本无此符号** | **该版本无此符号** | **该版本无此符号** | 0x3abc4 / 132 | 0x3f89c / 132 | 0x49084 / 132 |

补充符号（DDRC 深度终止电压链路所需，同样取自符号表）：

| 符号 | C15.0.0.126 | C15.0.0.821 | C15.0.0.861 | C16.0.0.212 | C16.0.5.701 | C17.0.0.100 |
|---|---|---|---|---|---|---|
| `ddrc_strategy_alloc` | 0x1183bc / 8 | 0x12cde8 / 8 | 0x12e680 / 8 | 0x1715ac / 8 | 0x19b7c4 / 8 | 0x1cc61c / 8 |
| `oplus_gauge_get_ratio_value` | 0x10d324 / 368 | 0x121688 / 368 | 0x122f20 / 368 | 0x1634bc / **368** | 0x18c87c / **560** | 0x1c2cf0 / **576** |
| `oplus_gauge_get_ddrc_status` | 0x10d498 / 1428 | 0x1217fc / 1444 | 0x123094 / 1444 | 0x1638a8 / 2048 | 0x18cd28 / 2056 | 0x1baf4c / 2552 |
| `oplus_gauge_ddrc_get_temp_region` | 0x10d2bc / 100 | 0x121620 / 100 | 0x122eb8 / 100 | 0x163430 / 136 | 0x18c7f0 / 136 | **该版本无此符号** |
| `oplus_gauge_update_ddrc_data` | **无** | **无** | **无** | 0x163630 / 628 | 0x18cab0 / 628 | **无** |
| `oplus_mms_gauge_set_deep_term_volt` | 0x10f938 / 580 | 0x123cb0 / 580 | 0x125548 / 580 | 0x16160c / 740 | 0x18a9d0 / 740 | 0x1b8f30 / 744 |
| `nfg8011b_set_term_volt` | 0x944e0 / **1984** | 0xa663c / 1092 | 0xa7280 / 1092 | 0xc79a0 / 1092 | 0xe1b90 / 1092 | 0x103790 / 1092 |
| `nfg8011b_get_sili_ic_alg_term_volt` | 0x938b8 / 460 | 0xa55c0 / 460 | 0xa6204 / 460 | 0xc691c / 460 | 0xe0b0c / 460 | 0x102520 / 460 |
| `oplus_get_three_level_term_volt` | **无** | **无** | **无** | 0x1b6e30 / 340 | 0x1e6ae4 / 340 | 0x23f70c / 340 |
| `oplus_gauge_get_three_level_term_volt` | **无** | **无** | **无** | 0x162ce0 / 384 | 0x18c0a0 / 384 | 0x1ba608 / 384 |

**符号表自身给出的第一条线索**：`ddrc_strategy_*` 的尺寸在 **C16.0.0.212（6.6.89）处发生一次阶跃**（1868→1964、1168→1156），此后 16.0.5.701 与 17.0.0.100 完全一致；`get_three_level_term_volt_show` 在 15.x 三份中**完全不存在**，从 C16.0.0.212 起才有。也就是说 15.x 与 16.x/17.x 之间存在**真实的实现重写**，下面 §2/§3 用指令级比对把它钉死。

---

## 2. 指令级等价性分组

方法：对每个函数取 `size` 字节反汇编，逐条比较；分级为
**① 字节相同** → **② 仅分支目标地址/日志行号不同**（可完全归因于模块内布局与源行号）→ **③ 存在行为相关差异**（结构体偏移、立即数、指令结构）。

### 2.1 分组结果

| 函数 | 15.0.0.126 ↔ 15.0.0.821 ↔ 15.0.0.861 | 16.0.0.212 ↔ 16.0.5.701 ↔ 17.0.0.100 | 15.0.0.861 ↔ 16.0.5.701 |
|---|---|---|---|
| `ddrc_strategy_alloc_by_node` | **组内两两 ②**（仅分支目标不同） | **组内两两 ②** | **③** 467 vs 491 条（见 §3.1） |
| `ddrc_strategy_init` | 821↔861 = ②；**126↔821 = ③**（同 292 条，差异为寄存器分配） | 两两 ② | **③** 292 vs 289 条（栈帧 0x60→0x50、寄存器分配） |
| `ddrc_strategy_get_data` | 两两 ② | 两两 ② | **②′** 仅日志行号（0x25f/0x263 → 0x273/0x277） |
| `ddrc_strategy_release` | 两两 ② | 两两 ② | **②′** 仅日志行号 |
| `oplus_get_deep_term_volt` | 821↔861 = ②；126↔821 = ③（126 条，118 条对齐） | 212↔701 = ③、701↔17 = ③（均为结构体偏移） | **③** 126 vs 129 条（结构体偏移） |
| `oplus_set_deep_term_volt` | 821↔861 = ②；126↔821 = ③（368 条，361 对齐） | 212↔701、701↔17 = ③（结构体偏移） | **③** 368 vs 372 条（结构体偏移） |
| `oplus_gauge_get_sili_ic_alg_term_volt` | 821↔861 = ②；126↔821 = ③ | 212↔701 = ③；701↔17 = ②′ | **③** 差异仅结构体偏移 0x236→0x277 + 行号 |
| `oplus_mms_gauge_get_sili_ic_alg_term_volt` | 821↔861 = ②；126↔821 = ③ | 组内 ③（结构体偏移） | **③** 152 条中**仅 3 条**行为差异：三个结构体偏移 0xf74→0x1a58、0xf78→0x1a60 |
| `get_three_level_term_volt_show` | **三份均无此符号** | 212↔701 = **① 字节完全相同**；701↔17 = **③**（1 处偏移 0x60→0x68） | 15.0.0.861 无此符号 |

### 2.2 "③"里到底变了什么（这一点决定结论）

对 6.6.66（715531c3）↔ 6.6.89（c6fedbc8）逐条归类后，行为相关差异**全部**属于下面三类：

1. **栈帧/寄存器分配**（`sub sp, sp, #0x70` → `#0x80`、`stp x28,x27,[sp,#0x20]` → `[sp,#0x30]`）——编译器行为，不改变算法。
2. **`struct oplus_chg_ic_dev` / drvdata` 结构体偏移**（0x236→0x277、0x108→0x118、0x2a8→0x2e8、0x56c→0x5ac、0xf74→0x1a58、0x60→0x68 等）——内核 6.6.66→6.6.89 之间结构体加字段，不改变逻辑。
3. **日志行号立即数**（`mov w2, #0x25f` → `#0x273`，即 `__LINE__`）——纯显示。

**没有出现**：阈值立即数变化、比较方向翻转、表行数/容量常量变化、`v_lo`/`v_hi` 取值字段变化、温档/ratio 取值来源变化。

---

## 3. 明显不同的那几处（贴反汇编）

### 3.1 `ddrc_strategy_alloc_by_node`（DT 表解析）：6.6.66 vs 6.6.89

**C15.0.0.861 @0x12e68c（467 条）关键序列：**
```
0x12e6d8  bl   kmalloc_trace              ; w1=#0xdc0(3520B), w2=#0x280  ← 同一个分配
0x12e6fc  bl   of_property_read_variable_u32_array
0x12e710  ldr  w8,[x8]                    ; oplus_log_level
0x12e764  bl   of_property_count_elems_of_size   ; w2=#4  ← ratio_range
0x12e790  bl   of_property_read_variable_u32_array
0x12e7a8  bl   of_property_count_elems_of_size   ; w2=#4  ← temp_range
0x12e7d4  bl   of_property_read_variable_u32_array
0x12e828  bl   of_get_child_by_name
0x12e83c  bl   of_property_count_elems_of_size
0x12e86c  bl   __kmalloc                  ; w1=#0xdc0
0x12e88c  bl   of_property_read_variable_u32_array
... (同样 5 组: count_elems(w2=#4) / __kmalloc(w1=#0xdc0) / read_variable_u32_array)
0x12edb4  add  x27, x27, #0x60            ; 元素 stride 0x60 字节 = 24 u32
0x12edb8  add  x28, x28, #8
0x12edbc  cmp  x27, #0x240                ; 循环上界 0x240 = 9*0x60 → 每次处理 5 个元素
```

**C16.0.5.701 @0x19b7d0（491 条）关键序列：**
```
0x19b824  bl   kmalloc_trace              ; w1=#0xdc0(3520B), w2=#0x298
0x19b84c  bl   of_property_read_string    ; 属性 = "oplus,gauge_topic_name"
0x19b868  bl   snprintf                   ; 格式 "%s"  ← 用 gauge topic name 拼子节点名
0x19b8e0  bl   of_property_read_variable_u32_array   ; oplus,temp_type (w3=#1)
0x19b914  bl   of_property_count_elems_of_size      ; w2=#4  ← "oplus,ratio_range"
0x19b940  bl   of_property_read_variable_u32_array
0x19b958  bl   of_property_count_elems_of_size      ; w2=#4  ← "oplus,temp_range"
0x19b984  bl   of_property_read_variable_u32_array
0x19b9cc  bl   of_get_child_by_name
0x19ba10  bl   __kmalloc                  ; w1=#0xdc0
... (同样 5 组)
0x19bb68  add  x28, x28, #0x60            ; stride 相同
0x19bb70  cmp  x28, #0x240                ; 上界相同
```

**差异含义**：6.6.89 把"子节点名"从**硬编码的 `strategy_temp_{cold,cool,normal,warm}` 字符串**（15.x 中这 4 个串出现在本函数的字符串引用里）改成**由 DT 属性 `oplus,gauge_topic_name` 经 `snprintf("%s")` 拼出来**。两者读取的属性集合相同：`oplus,ratio_range`、`oplus,temp_range`、`oplus,temp_type` + 4 个温档子节点；**每次读取的元素数校验（#4）与总容量（0xdc0 = 3520 B）完全一致**，行数/容量处理逻辑**没有变化**。

→ 这一段**不能**解释 3350/3250：同一份 DT 下解析出的 22 行 4 元组在两边逐项相同。

### 3.2 六份驱动内部都没有 DDRC 阈值表（关键否证）

用 `struct.pack` 在**每个 PROGBITS 节**里搜索任务书 §3 的 DT 行序列，逐版本结果：

| 被搜索的字节序列 | 15.0.0.126 | 15.0.0.821 | 15.0.0.861 | 16.0.0.212 | 16.0.5.701 | 17.0.0.100 |
|---|---|---|---|---|---|---|
| normal/warm min 5 行 `(0,3000,3060,0)...(1500,3300,3350,4)` | 0 次 | 0 次 | 0 次 | 0 次 | 0 次 | 0 次 |
| low / mid_low / mid_high normal 行 | 0 | 0 | 0 | 0 | 0 | 0 |
| cold 6 行 `(0,2800,3000,0)...(2000,3300,3350,5)` | 0 | 0 | 0 | 0 | 0 | 0 |
| 单行 `(1000,3200,3250,3)` / `(1500,3300,3350,4)` / `(0,3000,3060,0)` | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| u32 常量 `3250` | **0** | **0** | **0** | **0** | **0** | **0** |
| u32 常量 `3350` | **0** | **0** | **0** | **0** | **0** | **0** |
| u32 常量 `3060` | 0 | 0 | 1 | 1 | 0 | 1 |

（后者的 1 次出现在 `oplus_pps_probe`/`oplus_comm_*` 等无关函数，是普通立即数，不是表项。）

另外，**ratio 分档阈值 `20/30/50/70/90` 在六份驱动里都不是 `cmp` 立即数**（逐函数扫描 6 份：命中 0 个函数）。也就是说驱动**从不硬编码任何 DDRC 阈值或分档边界**——它们 100% 来自 DT。

**含义**：既然六份驱动内都没有 3250/3350 这两个值，那么"驱动实发 3250 vs 模块算 3350"**不可能**是"某个驱动版本把表写死成 3250"。表的唯一来源是 DT，而 DT 逐项相同。

### 3.3 `oplus_get_deep_term_volt`（模块 hook 的那一层）：逻辑不变

**C16.0.5.701 @0xcb8a0：**
```
0xcb8d4  ldrb w8, [x20, #0x277]      ; C15.0.0.861 为 [x20,#0x236] —— 结构体偏移变了，语义同
0xcb8e4  bl   nfg8011b_get_define_term_volt        ; nfg8011b 专用路径（走该函数）
0xcb950  bl   bq27541_i2c_txsubcmd    ; w1=0x3e, w2=0x4a
0xcb974  bl   bq27541_read_i2c_block  ; w1=0x3e, w2=0xc  (读 12 字节)
0xcb990  orr  w21, w8, w9, lsl #8     ; 组字
0xcb9b8  lsr  w8, w21, #1             ; ★ 读到的 IC 值 = 组合值 >> 1
0xcb9c0  str  w8, [x19]
0xcb9c4  str  w8, [x20, #0x5ac]       ; C15 为 [x20,#0x56c] —— 偏移变了，语义同
```
C15.0.0.861 @0xa1e18 的同一序列逐条对应，**连 `mov w1,#0x3e / w2,#0x4a / w2,#0xc`、`orr ... lsl #8`、`lsr #1` 这些立即数都完全一样**。这是本问题的核心点之一：

- 模块 hook 到的"驱动实发"值，在其中一条分支上是**直接从电量计 IC 读回的寄存器内容再 `>>1`**（`0x3e/0x4a` → block read `0x3e/0x0c`）。这条路径**与 DDRC 策略表无关**，同样**与驱动版本无关**——它反映的是 IC 里当时那 12 字节。
- 另一条分支（`nfg8011b_get_define_term_volt`，`battery_type = silicon_p_770` 时走）在六份驱动中**尺寸 552/552/552/556/556/556**，逻辑同样只是结构体偏移差异。

### 3.4 唯一的真实行为分歧：`oplus_gauge_get_ratio_value`（ratio 的算法）

| 版本 | 尺寸 | 说明 |
|---|---|---|
| C15.0.0.126 / 821 / 861 | 368 / 368 / 368 | 基础式：`ratio = (10 × counts) / cc`（cc = GAUGE_ITEM_CC；**原写"电压"有误，见 §8 更正**） |
| C16.0.0.212 | 368 | 与 15.x 同尺寸（本函数此刻还没改） |
| C16.0.5.701 | **560** | **新增 SOH 补偿分支** |
| C17.0.0.100 | **576** | 同上 |

C16.0.5.701 新增部分（@0x18c95c 起）：
```
0x18c95c  bl   oplus_get_gauge_type
0x18c978  cmp  w20, #1               ; gauge_type == 1 ?
0x18c984  bl   oplus_gauge_get_dec_cv_soh      ; ★ 该符号在 15.x 三份中不存在
0x18c9a0  tbnz w19, #0x1f, ...       ; soh 有效才采纳
0x18c9a4  str  w19, [x22]            ; 用 soh 覆盖分子来源
0x18c9bc  cbz  w23, ...
0x18c9c0  add  w8, w23, w23, lsl #2  ; w8 = 5 × counts
0x18c9c4  lsl  w8, w8, #1            ; w8 = 10 × counts
0x18c9cc  add  w9, w23, w23, lsl #2  ; 同样 10 × counts
0x18c9d0  lsl  w9, w9, #1
0x18c9d4  sdiv w8, w9, w8            ; ★ 除数由 soh 分支决定
```
符号核对：`oplus_gauge_get_dec_cv_soh` 在 15.0.0.126/821/861 中**不存在**，在 16.0.0.212 起存在（用含 "soh"/"dec_cv" 的符号数量侧面确认：15.x ≈ 30，16.0.5.701 ≈ 67，17.0.0.100 ≈ 109）。基础式（`10×counts / cc`，§8 更正）在 15.x 与 16.x 中都存在；16.0.5.701 起**在 gauge_type==1 且 SOH 有效时**会走另一条除数。

**这是全链条里唯一能"对同一份 counts/cc 算出不同 ratio"的驱动侧改动**，而 ratio 直接决定选哪一行（见 §4），所以它是**唯一尚未排除的驱动侧解释**。诚实标注：我**没有**验证在 SOH=100 时该分支是否真的会算出与基础式不同的数值（要跟 `oplus_gauge_get_dec_cv_soh` 的返回值语义，属于深挖，超出本次范围）。

### 3.5 `get_three_level_term_volt_show`：15.x 无此符号

33 条指令，C16.0.0.212 与 C16.0.5.701 **字节完全相同**，C17.0.0.100 仅 1 处结构体偏移（`ldr x0,[x8,#0x60]` → `[x8,#0x68]`）。整个函数就是"取 ic dev 的某字段 → `snprintf(...,0x80,...)` 打印"，**不含任何阈值比较**。这与实测 `get_three_level_term_volt = first=0,second=0,third=0` 一致：它是 16.x 才有的、且**没有值可打**的 sysfs。它**不是** 3350 的来源。

---

## 4. 与 3060/3250/3350 有关的常量与选行逻辑（本次比对确认到的）

- 六个版本中 `ddrc_strategy_get_data` 都只是**24 字节结构体拷贝**（`ldr x8,[x8,#0x10]` → `ldp/ldr` → `str/stp` 到 `[x1]`），**没有任何表查找或阈值比较**；且 6.6.89 上本函数**没有任何调用者**（`c6fedbc8` 中 0 个 caller；`c75d23e6` 中 2 个，都在 `mpc7022_*` 路径）。它不是 3350/3250 的来源。
- `oplus_gauge_get_ddrc_status`（两端都在）内含**同一段选行循环**：`cmp x10,x20` / `cmp w10,w12`（阈值比较）→ `ldp w20,w21,[x8,#4]`（取 4 元组第 2/3 个字段，即 `v_lo`/`v_hi`）→ `str w12,[x19,#0xe7c]`。这一段在 6.6.66 与 6.6.89 上**结构一致**（6.6.89 版本额外多出 voter/日志与 `oplus_gauge_update_ddrc_data` 调用，选行本身的比较与取值字段未变）。
- 4 元组 16 字节、`0x258`/`0x26c` 等字段偏移在 6.6.66/6.6.89 上**相同**；表容量 `0xdc0` 与 stride `0x60` 相同；行数校验都在解析处用 `cmp w21,#5`/`cmp w21,#3` 逐属性校验。
- 遍历所有函数找 `1758/3250/3350/3060/3000/3150/3300` 立即数：命中的都是**无关函数**（`nu1669_checksum_fw`、`sub_batt_thermal_read_temp`、`oplus_ufcs_monitor_work`、`oplus_comm_*` 等），且每次版本命中点都在漂移——没有任何一处构成 DDRC 表语义。

---

## 5. 结论

### 5.1 判定

**3350 vs 3250 的差异不能由驱动版本解释**（"表被换掉/常量被改"这一路径被否证）。

依据（全部为本次实际比对所得）：
1. 六份驱动内**都不存在** DDRC 阈值表内容：逐行 4 元组 0 命中，u32 `3250` 0 命中，u32 `3350` 0 命中。
2. ratio 分档边界 `20/30/50/70/90` 在六份里都不是 `cmp` 立即数（0 个函数命中）⇒ 分档边界也来自 DT。
3. `ddrc_strategy_alloc_by_node` 读取的属性集合、元素数校验、行容量与遍历上界在 6.6.66 与 6.6.89 上**完全一致**（差异仅"子节点名由硬编码改为 snprintf 拼装"）。
4. `ddrc_strategy_get_data`/`ddrc_strategy_release` 跨 6.6.66↔6.6.89 仅差日志行号；`oplus_get_deep_term_volt`/`oplus_set_deep_term_volt`/`oplus_mms_gauge_get_sili_ic_alg_term_volt` 仅差结构体偏移与栈帧（后者 152 条中仅 3 条差异，均为结构体偏移）。
5. 模块 hook 的读取层在一条分支上是 `IC 寄存器 → orr → >>1`（`0x3e/0x4a`、`0x3e/0x0c`、`lsr #1` 三个立即数跨版本完全相同），与策略表、与版本都无关。

### 5.2 因此差异更可能在运行时输入

`3250` 与 `3350` 在 DT 里是**同一张表里相邻两行的不同字段**（例如 normal/warm 5 行表中：第 4 行 `(1000,3200,3250,3)`、第 5 行 `(1500,3300,3350,4)`）。选哪一行取决于**实时 ratio**；而 ratio 由 `(10 × deep_dischg_counts) / cc` 得到（**原写 "/ 电压" 有误，见 §8 更正**），其中 **cc 与 counts 都是实时值**。也就是说：

> 同一条机、同一份 DT，只要"模块算 3350"与"驱动实发 3250"这两个时刻的 **ratio**（或它依赖的电压/counts）不同，就会分别落在 1500 档和 1000 档，输出 3350 与 3250——**无需任何版本差异**。

需要提请上级注意的两个未闭合点：

1. **`oplus_gauge_get_ratio_value` 的 SOH 补偿分支（C16.0.5.701 起，560 B）**：它是唯一可能对同一份 counts/cc 算出不同 ratio 的驱动改动。本次未验证 SOH=100 时两条式子的数值是否相同。若上级要彻底关闭"版本"这条线，下一步应逆向 `oplus_gauge_get_dec_cv_soh` 并代入 SOH=100 实算两支。
2. **读数时刻问题**：模块记录的 3350 是"C15.0.0.861(6.6.66) 上模块记录"的历史观测，而 3250 是"C16.0.5.701(6.6.89)"上的观测——两者**不是同一时刻的对照测量**；温度 35.6 °C 与 counts 1758 是**当前**读数。跨时刻比较本身就会引入输入差异（尤其 `deep_dischg_counts` 随放电累积变化）。

### 5.3 版本演进时间线（与本问题相关的部分）

| 边界 | 变化 | 对 3350/3250 的影响 |
|---|---|---|
| 15.0.0.126 → 15.0.0.821 | `ddrc_strategy_init`、`oplus_get_deep_term_volt`、`oplus_set_deep_term_volt` 的寄存器分配差异（无行为差异） | 无 |
| 15.0.0.821 → 15.0.0.861（6.6.30→6.6.66） | 目标函数全部"仅分支目标地址不同" | 无 |
| **15.0.0.861 → 16.0.0.212（6.6.66→6.6.89）** | `ddrc_strategy_alloc_by_node` 467→491 条；新增 `ddrc_v2_strategy_register`、`oplus_gauge_update_ddrc_data`、三电平相关 5 个符号；`get_three_level_term_volt_show` 首次出现 | **无**（表与选行不变） |
| **16.0.0.212 → 16.0.5.701（同为 6.6.89）** | `oplus_gauge_get_ratio_value` 368→560 B（**新增 SOH 补偿**）；新增 `oplus_mms_gauge_set_deep_term_volt_work`；`oplus_set_deep_term_volt` 失去 caller | **潜在**（唯一未排除项） |
| 16.0.5.701 → 17.0.0.100 | 结构体偏移 + 日志行号；`oplus_get_three_level_term_volt0` 新增 | 无 |

---

## 6. 复核指引（命令）

```sh
# 符号表（本报告 §1）
python3 逆向脚本与产物/scripts/re_b_table.py
# 指令级等价性分组（§2）
python3 逆向脚本与产物/scripts/re_b_equiv.py
# DT 解析差异（§3.1）
python3 逆向脚本与产物/scripts/re_b_numdiff.py ddrc_strategy_alloc_by_node coloros15.0.0.861 coloros16.0.5.701
# 表内容否证（§3.2）
python3 逆向脚本与产物/scripts/re_b_tables.py
# 常量扫描（§3.2/§4）
python3 逆向脚本与产物/scripts/re_b_const.py
```

注：这些 .ko 的**所有节 VMA 均为 0**（`llvm-objdump -h` 可复核），符号 `st_value` 是节内偏移；因此"地址"跨版本不可直接比较，只能按符号名定位后再比指令。本报告的跨版本比较一律基于**指令文本**而非地址。

---

# 追加节：ratio 算式与选行定论（RE-B 第二批，C16.0.5.701 / c6fedbc8）

方法升级：六份 ko **都带 .BTF 段**（类型信息完整）。本节的字段名/枚举名**全部来自 BTF**（自解 split-BTF：base 字符串长度 2481276、base 类型数 140925），并用反汇编交叉验证。**本节结论默认"已证实"，否则显式标注"推测"。**

## 7. 结构 `oplus_mms_gauge`（BTF，size=0x24a8）

| 绝对偏移 | 字段 | 说明 |
|---|---|---|
| 0x0fd0 | `deep_spec` | 类型 `deep_dischg_spec`（size 0xa10，即 0xfd0..0x19e0） |
| 0x19e0 | `ddrc_strategy` | 每电池策略句柄数组（由 `oplus_gauge_parse_deep_spec` 写入） |
| 0x19e8 | `ddrc_curve` | 类型 `ddrc_temp_curves` = {`ddrc_strategy_data *`, `index_r`, `index_t`, `num`} |
| 0x1a00 | `ddrc_curve_sub` | 副电池 |
| 0x1a18 | `ddrc_num` | |
| 0x1a58 / 0x1a68 / 0x1a6c | `child_num` / `main_gauge` / `sub_gauge` | |
| 0x1b00 / 0x1b08 | `gauge_term_voltage_votable` / `gauge_shutdown_voltage_votable` | 终止电压 / 关机电压投票口 |

### 7.1 `deep_dischg_spec`（BTF，size=0xa10，基址 0xfd0）

| 绝对偏移 | 字段 | 含义 |
|---|---|---|
| **0x0fd4** | `counts`（与 +0x8 `sub_counts` 成对） | **deep_dischg_counts**。独立证实：`deep_dischg_counts_show` → `oplus_gauge_show_deep_dischg_count` 读的正是 `[chip+0xfd4]`/`[chip+0xfd8]` 并返回较大值 |
| 0x0fd8 | `sub_counts` | 副电池 counts |
| **0x0fdc** | `cc`（与 +0x10 `sub_cc` 成对） | **库仑计值 GAUGE_ITEM_CC**，见 §8 |
| 0x0fe0 | `sub_cc` | |
| **0x0fe4** | `ratio`（与 +0x18 `sub_ratio` 成对） | 驱动算出的 ratio |
| 0x0fe8 | `sub_ratio` | |
| 0x1020 / 0x1030 | `ddrc_tbatt` 温区数组 / 当前温度 | 温区分档输入 |
| 0x1828 | `term_coeff`（数组） | 模块 DT 走查用的那张表 |
| **0x1918** | `deep_dischg_limits`（size 0x60） | 见下表 |
| 0x19f8 | `term_coeff_size` | |

`deep_dischg_limits`（基址 0x1918）：

| 绝对偏移 | 字段 |
|---|---|
| 0x1918 / 0x191c | `uv_thr` / `target_uv_thr` |
| **0x1920** | **`count_thr`** —— 选行结果写在这里 |
| **0x1924** | **`count_cali`** —— 选行阈值的校准量。独立证实：`oplus_gauge_set_deep_count_cali` 写它、`oplus_gauge_get_deep_count_cali` 读它，对应 sysfs `deep_dischg_count_cali` |
| 0x192c / 0x1930 | `term_voltage` / `target_term_voltage` |
| 0x193c | `ratio_default` = sysfs `deep_dischg_ratio_thr`（实测 30） |
| 0x1950 | `ddrc_strategy_name`（指针） |

`ddrc_strategy_data`（BTF，16 字节/行）= `{?, vbat0(+4), vbat1(+8), ?}` ⇒ **DT 4 元组 = (阈值 f0, vbat0, vbat1, idx)**，`vbat0`=v_lo、`vbat1`=v_hi。

## 8. Q1：`oplus_gauge_get_ratio_value`（C16.0.5.701 @0x18c87c，560 B）完整算式

输入两项（均已证实）：

| 项 | 来源 | 反汇编证据 |
|---|---|---|
| 被除数因子 `A` | `[chip+0xfd4]` = `deep_spec.counts` = **deep_dischg_counts**（副电池走 0xfd8） | `0x18c8f0 add x8,x0,#0xfd4` → `0x18c8f4 ldr w23,[x8]` |
| 除数 `X` | `oplus_mms_get_item_data(ic, 8, &v, 1)` → **item 8 = `GAUGE_ITEM_CC`** | `0x18c900 mov w1,#8`；`0x18c8f8 mov x2,sp`；`0x18c908 bl oplus_mms_get_item_data` |

BTF 枚举 `gauge_topic_item`：SOC=0, VOL=1, VOL_MAX=2, VOL_MIN=3, GAUGE_VBAT=4, CURR=5, TEMP=6, FCC=7, **CC=8**, SOH=9, RM=10, ... ⇒ **item 8 就是库仑计 cc**。

算式（逐步对应指令）：

```
0x18c958  str  w8, [x22]        ; [chip+0xfdc] = X            <- 先缓存 cc
0x18c9a8  ldr  w8, [x22]        ; w8 = X                      (SOH 分支可能已覆盖, 见 §9)
0x18c9ac  mov  w9, #-0x1388     ; -5000
0x18c9b0  add  w10, w8, w9      ; w10 = X - 5000
0x18c9b4  cmp  w10, w9
0x18c9b8  b.hi 0x18c9cc         ; * 仅当 0 < X < 5000 才走除法
0x18c9bc  cbz  w23, 0x18c9dc    ;   (A==0 -> 100)
0x18c9c0  add  w8, w23, w23, lsl #2   ; w8 = A*5
0x18c9c4  lsl  w8, w8, #1             ; w8 = A*10     <- 非除法支路: ratio = 10*A
0x18c9c8  b    0x18c9e0
0x18c9cc  add  w9, w23, w23, lsl #2   ; w9 = A*5
0x18c9d0  lsl  w9, w9, #1             ; w9 = A*10
0x18c9d4  sdiv w8, w9, w8             ; * ratio = (10*A) / X
0x18c9dc  mov  w8, #0x64              ; 100
0x18c9e0  str  w8, [x21]              ; [chip+0xfe4] = deep_spec.ratio
```

**公式：`deep_spec.ratio = (10 x deep_dischg_counts) / cc`**

- **没有电压、电流、FCC 参与**；除数是 **cc（库仑计）**，不是我上一版报告写的"电压"——**上一版该处措辞有误，本节更正**；被除数确实是 counts。
- 限幅只有一处：`0 < X < 5000` 的合法窗（0x18c9ac-0x18c9b8）。窗外：`ratio = 10*counts`（counts≠0）或 `100`（counts=0）。结果不再做 min/max。
- 结果写入 `deep_spec.ratio`(0xfe4)；`oplus_mms_gauge_update_ratio_limit_curr` 同时读 0xfe4 与 0xfdc 两个值。

## 9. Q2：SOH 分支

- `oplus_gauge_get_dec_cv_soh`（@0x16920c，C16.0.5.701）：调 ic debug func **id 0x1ee**，成功返回该 u32。实现之一 `oplus_bq27541_get_dec_cv_soh`（@0xcc0ac，120 B）读 `ic->priv->[0x30]`（`ldr x8,[x8,#8]; ldr x8,[x8,#0x98]; ldr w8,[x8,#0x30]`）——**缓存字段，驱动侧无单位换算**（量纲即该字段量纲，我未追到写入点）。
- **参与方式：整项替换除数**。`0x18c9a4 str w19,[x22]` 把 SOH 写回 `[chip+0xfdc]`（覆盖刚缓存的 cc），随后 `0x18c9a8 ldr w8,[x22]` 取它作除数。**由于 0xfdc 同时是 §10 选行的比较对象，该分支会同时改变 ratio 与选行输入。**
- 触发条件：`0x18c978 cmp w20,#1 ; b.ne` ⇒ 仅当 `oplus_get_gauge_type()==1`；且 `0x18c9a0 tbnz w19,#0x1f` ⇒ SOH 为负时不覆盖。
- BTF 枚举 `gauge_type_id`：0=BQ27541, **1=BQ27411**, 2=BQ28Z610, 3=ZY0602, 4=ZY0603, 5=NFG8011B, 7=SN28Z729, 8=MPC7022。
- **15.x 三份完全没有 `oplus_gauge_get_dec_cv_soh` 符号**（逐份符号表确认）⇒ 15.x 除数**永远是 cc**。
- **SOH=100 时两支是否相同**：
  - 6.6.66(715531c3)：`ratio = 10*counts/cc`，选行输入 = **cc**。
  - 6.6.89(c6fedbc8) 且 gauge_type==1：`ratio = 10*1758/100 = 175`，选行输入 = **100**。
  - ⇒ **只要 cc ≠ 100 就不同**（cc 是库仑计，典型数百至数千）。**但该支仅在 gauge_type==1 时生效。**
  - 反证（**推测**）：C16.0.5.701 中三个 per-IC 实现 `oplus_bq27541_get_gauge_type`/`oplus_bq27561_get_gauge_type`/`oplus_sn28z729_get_gauge_type` **全部返回常数 2**（`mov w8,#2; str w8,[x1]`），而 nfg8011b 对应 5 ⇒ 本机 gauge_type 很可能 ≠ 1 ⇒ SOH 分支不生效。

## 10. Q3：选行规则定论（`oplus_gauge_update_ddrc_data` @0x18cab0）

```
0x18cb24  ldr  w24, [x21, #0x19f8]   ; w24 = chip->ddrc_curve.num (行数)
0x18cb30  ldr  w9,  [x21, #0xfdc]    ; * X = deep_spec.cc (或 SOH)
0x18cb54  cmp  x24, #2
0x18cb58  b.lt 0x18cb88              ; i<2 -> i=0
0x18cb5c  sub  x24, x24, #1          ; i--
0x18cb60  ldr  w11, [x21, #0x1924]   ; count_cali
0x18cb68  lsl  x10, x10, #4          ; i*16
0x18cb6c  ldr  w10, [x8, x10]        ; row[i].f0
0x18cb70  subs w10, w10, w11         ; f0 - count_cali
0x18cb74  csel w10, wzr, w10, lt     ; max(0, ...)
0x18cb78  cmp  w9, w10               ; * X vs (f0 - count_cali)
0x18cb7c  b.lt 0x18cb54              ; X < thr -> 继续往小 index 找
0x18cb80  str  w10, [x21, #0x1920]   ; limits.count_thr = 选中阈值
```

**规则：`选中 index = max{ i : max(0, row[i].f0 - count_cali) <= X }`；若 i>=1 全不满足则取 0。**

- 比较方向：**阈值 ≤ X，含等号**（`b.lt` 只在 X < 阈值时继续下移）。
- **比较对象是 `X = deep_spec.cc`（库仑计 GAUGE_ITEM_CC）**，既不是 `deep_dischg_counts`，也不是 `ratio`；阈值还要先减 `limits.count_cali`。
- **⇒ A 的模型「取 阈值 ≤ counts 的最后一行」不成立**：对象用错（counts vs cc），且漏掉 `count_cali` 修正。它只在 counts=1758 很大时"碰巧"也落到最后一行。
- 15.x 同结构（cc 在 0x99c、ratio 在 0x9a4、count_cali 在 0xe80、count_thr 在 0xe7c），循环同样 `cmp w10,w12` / `b.lt`。**两版选行算法一致**（这也解释了为什么上一版报告里"跨族只差结构体偏移"）。
- 输出映射（`oplus_gauge_get_ddrc_status`）：`row.vbat1`(+8) → `gauge_term_voltage_votable`(0x1b00)（即"电量计终止电压"）；`row.vbat0`(+4) → `gauge_shutdown_voltage_votable`(0x1b08)。呼叫点 0x18d0b8 / 0x18d0dc。

## 11. Q4：代入实测值

命中行取决于两个我尚未拿到的运行时量，故给出判定表。f0 按任务书 §3 的 normal/warm 行（min: 0,15,500,1000,1500；mid_low: 0,15,300,600,900；mid: 0,100,300,600），v_hi 一律 [3060,3060,3150,3250,3350]。

情形 1（6.6.66，X = cc，count_cali 记为 C，取 C=0）：

| 条件 | v_hi |
|---|---|
| cc >= 1500（min 表）/ cc >= 600（mid 表） | **3350** |
| 1000 <= cc < 1500（min 表）/ 300 <= cc < 600（mid 表） | **3250** |

情形 2（6.6.89 且 gauge_type==1，X = SOH = 100）：`thr_i = f0_i - C`，X=100 ⇒ **C ∈ [900,1399] 时命中 index 3 ⇒ 3250**；C<900 ⇒ 3060/3150；C>=1400 ⇒ 3350。（若 dec_cv_soh 量纲为 0.1%（即 1000），则 X=1000、C=0 亦命中 index 3 ⇒ **3250**。）

**结论（分两层）：**

1. **已证实**：3350 与 3250 在同一张 DT 表内是**相邻两行的 `vbat1`**，命中哪一行完全由 `X = deep_spec.cc`（或 6.6.89 上被 SOH 覆盖后的值）与 `count_cali` 决定；`deep_dischg_counts`(1758) **不参与选行**，只参与 ratio。
2. **推测（待真机两个读数确认）**：模块的 3350 来自"用 counts 当比较对象"（1758 很大 ⇒ 必中最后一行 ⇒ 3350）；驱动的 3250 来自"用 cc 当比较对象"（cc 落在中间档 ⇒ 命中倒数第二行 ⇒ 3250）。**这条不需要任何版本差异**，是"同一份 DT、不同比较输入"的必然结果，即任务书最初怀疑的"模块查错了表/列"。

**需要的真机读数（不要 vbat）：**
1. `/sys/class/oplus_chg/battery/gauge_type`（`gauge_type_show` → `oplus_get_gauge_type`，与 §9 分支判定同一函数）——若为 1 则 SOH 分支生效；
2. `/sys/class/oplus_chg/battery/deep_dischg_count_cali`（= C）；
3. **cc 值**（GAUGE_ITEM_CC）：请 `ls /sys/class/oplus_chg/battery/` 找 `*cc*`/`*coul*` 节点，或 `/sys/class/power_supply/battery/charge_counter`（标准节点，单位 µAh，除以 1000 得 mAh）。

~~仍未验证：ddrc_curve.index_r 的选择代码~~ → **已消除，见 §12**：region 由 ratio 与 ratio_range[20,30,50,70,90] 逐级比较得出（边界归上档），region 0..5 = min/low/mid_low/mid/mid_high/high（§12.7 已证）。

---

# §12 ratio → 表 选择的代码级定证（RE-B 第三批，C16.0.5.701 / c6fedbc8）

上一节唯一的未验证项已闭环。以下除显式标注「推测/未证」外，全部为**代码级已证实**。

## 12.1 调用链（已证实）

```
oplus_gauge_update_ddrc_data (0x18cab0)
  -> oplus_chg_strategy_init(strategy)                    (0x195f28; KCFI 校验后 blr desc->init)
       -> ddrc_strategy_init  V1 @0x19c054 / V2 @0x19d018   <== ★ region 选择就在这里
  -> oplus_chg_strategy_get_metadata(strategy,&meta)       (0x196184; blr [desc+0x48])
       -> ddrc_strategy_get_metadata @0x19c578  : 把 strategy->cur 的 24 字节拷进 chip->ddrc_curve
  -> 用 chip->ddrc_curve.data / .num 选行 (§10)
```

注册两支实现：`ddrc_strategy_register`(0x19b79c, V1) 与 `ddrc_v2_strategy_register`(0x19c614, V2)；`deep_dischg_spec.ddrc_strategy_v2`(chip+0x19d4) 选支（`oplus_gauge_ddrc_get_temp_region` 0x18c808 即在读它）。**两支 selection 结构相同**。

## 12.2 Q1：比较对象 / 方向 / 边界归属（已证实）

```
0x19c090  add  x0, x19, #0x280        ; x19 = 策略数据缓冲; +0x280 = topic 名字串
0x19c094  bl   oplus_mms_get_by_name  ; 取该名字的 topic ic (缓存到 [x19+0x290])
0x19c0a4  mov  w1, #0x1e              ; ★ item 0x1e = 30 = GAUGE_ITEM_RATIO_VALUE
0x19c0ac  bl   oplus_mms_get_item_data; -> ratio 值 (w8)
0x19c0b8  ldr  w9, [x19, #0x258]      ; ratio_range[0] = 20
0x19c0bc  cmp  w8, w9
0x19c0c0  b.hs 0x19c114               ; ratio >= 20 -> 继续上探; 否则 region=0 (0x19c0c4 mov w22,wzr)
0x19c114  ldr  w9,[x19,#0x25c] (=30) ; cmp ; 0x19c11c b.hs -> 否则 region=1 (0x19c120)
0x19c2a4  ldr  w9,[x19,#0x260] (=50) ; cmp ; 0x19c2ac b.hs -> 否则 region=2 (0x19c2b0)
0x19c2c0  ldr  w9,[x19,#0x264] (=70) ; cmp ; 0x19c2c8 b.hs -> 否则 region=3 (0x19c2cc)
0x19c32c  ldr  w9,[x19,#0x268] (=90) ; cmp ; 0x19c334 mov w8,#4 ; 0x19c338 cinc w22,w8,hs
                                      ;   ratio>=90 -> 5, 否则 4
```

- 比较对象 = `oplus_mms_get_item_data(gauge_topic, 0x1e, ...)`，即 **`GAUGE_ITEM_RATIO_VALUE`（BTF 枚举 gauge_topic_item = 30）**。它与 `oplus_gauge_get_ratio_value` 算出的 `deep_spec.ratio`(0xfe4) 的同一性属**强推断（未证）**：同名同量纲、DDRC 链路里唯一读取者，但我没追到发布侧的 store。
- 方向：升序逐级比较，**`b.hs`（无符号 ≥）** ⇒ **边界值全部归上档**：

| ratio 区间 | region | 依据 |
|---|---|---|
| ratio < 20 | 0 | 0x19c0c4 |
| 20 <= ratio < 30 | 1 | ratio==20 落 1 |
| 30 <= ratio < 50 | 2 | ratio==30 落 2 |
| 50 <= ratio < 70 | 3 | ratio==50 落 3 |
| 70 <= ratio < 90 | 4 | ratio==70 落 4 |
| ratio >= 90 | 5 | ratio==90 落 5 (`cinc ...,hs`) |

温度维 index_t（同函数，已证实）：
```
0x19c160  mov  w1, #0x1f              ; item 0x1f = 31 = GAUGE_ITEM_RATIO_TRANGE
0x19c168  bl   oplus_mms_get_item_data
0x19c174  tbnz w8,#0x1f               ; 负值 -> 改走温度计算
0x19c178  cmp  w8, #4 ; 0x19c17c b.lt 0x19c39c   ; trange<4 -> 直接当 index_t
0x19c194  item 6 (temp_type==0) / 0x19c210 item 0xe (temp_type==1)
0x19c220  ldr w8,[sp,#0x10] (温度) ; 0x19c224 ldr w9,[x19,#0x26c] (= -50)
0x19c228  cmp ; 0x19c22c b.le -> index_t=0 (0x19c2b8)   ; <= -5.0C
0x19c230/38 vs [x19+0x270] (=100) ; b.le -> index_t=1 (0x19c304) ; <=10.0C
0x19c23c/40 vs [x19+0x274] (=350) ; mov w8,#2 ; cinc w8,w8,gt -> >35.0C 则 3
```
⇒ index_t∈{0,1,2,3}，边界**归下档**（`b.le`）：<=-5.0C→0、(-5.0,10.0]→1、(10.0,35.0]→2、>35.0→3（0.1C 单位，与 DT `oplus,temp_range=[-50,100,350]` 一致）。

最终落点（已证实）：
```
0x19c39c  mov w9,#0x60 ; mov w10,#0x18
0x19c3a4  umaddl x9, w22(region), w9, x19    ; x9 = 数据基址 + region*0x60
0x19c3a8  umaddl x9, w8(index_t), w10, x9    ; x9 += index_t*0x18
0x19c3ac  stp w22, w8, [x9, #0x20]           ; 把 (region,index_t) 写进该 descriptor 的 +8/+0xc
0x19c3c0  str x11, [x19, #0x10]              ; x11 = x9+0x18 -> strategy->cur = 选中 descriptor
```
⇒ 每个 region 记录 0x60 字节 = **4 个 0x18 字节 descriptor**（{rows 指针, index_r, index_t, num}），与 §7 的 alloc 布局（记录自 +0x18 起、stride 0x60、每记录 4 个子数组）完全吻合。

## 12.3 Q2：region ↔ 六个名字的对应

- **取名方式（已证实）**：`of_get_child_by_name(node, name)`（0x19b9cc）——**按名字精确匹配**，不是 `of_get_next_child`。名字来自**硬编码 6 指针数组**：0x19b9a8 `adrp x25` / 0x19b9ac `add x25,x25,#0`，循环内 `add x25,x25,#8`（0x19bb6c），共 6 次（`cmp x28,#0x240`，0x19bb70，stride 0x60）。
- ⇒ **region 索引 = 该数组下标**（第 i 个名字 ↔ `data+0x18+i*0x60` 记录），已由 12.2 的 `region*0x60` 从另一侧反证。
- 每个子节点内部用 4 个属性名读 4 条温度数组：`strategy_temp_cold / cool / normal / warm`（这 4 个串在本函数被引用，已证实）⇒ 每节点 4 条 descriptor ✓ 与 DT「6 个 ratio 节点 × 4 温度数组」一致。
- **已解出（重定位交叉验证；见 §12.7）**：那 6 个指针数组在 .rodata+0x16bc0（V2 用同内容的另一份拷贝 .rodata+0x16c10），6 项依次为 **strategy_ratio_range_min / _low / _mid_low / _mid / _mid_high / _high**。故 **region 0..5 = min, low, mid_low, mid, mid_high, high（已证实）**，原推测消除。
- 旁证（保留）：各档表内 f0 阈值随档位递减（min 用 0/400/800，high 用 0/50/100），ratio 越大 → region 越大 → 同一 cc 命中越靠后 → v_hi 越大，与观测 3060→3150→3250 一致。

## 12.4 Q3：超范围 / 缺失回退（已证实）

| 情形 | 行为 | 地址 |
|---|---|---|
| ratio < 20 | region = 0 | 0x19c0c4 |
| ratio >= 90 | region = 5 | 0x19c334/0x19c338 |
| item 0x1e 读取失败(rc<0) | **region = 5**（取最高档，不是 0） | 0x19c0b0 tbnz → 0x19c134 `mov w22,#5` |
| item 0x1f 失败/为负 | 改由温度算 index_t；温度亦失败则 index_t = 3 | 0x19c174 → 0x19c398 |
| ratio 子节点缺失 | `of_get_child_by_name` 返回 NULL → 0x19b9d0 `cbz x0` → 0x19bd9c 错误路径（log can not find node + 释放 + 返错）⇒ **整实例 alloc 失败，非单档回退** | 0x19b9d0 / 0x19bd9c |
| `oplus,temp_type` 非 0/1 | log + 返错 | 0x19c190 cbnz w3 → 0x19c250 |

## 12.5 Q4：选行输入确认（已证实，同 §10）

`0x18cb30 ldr w9,[x21,#0xfdc]`（= `deep_spec.cc`，由 GAUGE_ITEM_CC 填入、SOH 分支生效时被 SOH 覆盖）作为 X；`0x18cb60 ldr w11,[x21,#0x1924]`（= `deep_dischg_limits.count_cali`，sysfs `deep_dischg_count_cali`）作为修正；`0x18cb70 subs` → `max(0, f0-count_cali)`；`0x18cb78 cmp ; b.lt` ⇒ 取「阈值 ≤ X 的最后一行」。**两项假设成立。**

## 12.6 与「行为反推时间线」是否一致

- 一致的机制：`v_hi = 表[region(ratio)][index_t(temp)] 第 k 行的 vbat1`，`k = max{ i : f0_i - count_cali <= cc }`。ratio / temp / cc 三个输入**各自都能单独把档位抬起来**。
- 需提醒：若把 `3060(counts 0~763, cc 57~172)` 读成「区间内 v_hi 恒为 3060」，与代码有冲突——`ratio = 10*counts/cc` 在该区间可从 0 漂到 100+（如 counts=763, cc=57 → ratio≈134 → region 5），region 一变表就变。**若厂商快照里 counts 区间与 cc 区间不是同一时刻成对采样，该读法不成立**；请用成对样本 (counts_i, cc_i, temp_i) 按上式逐点复算——代码侧规则现已完全确定，可直接当判据。

**本节结论**：§11 中「ddrc_curve.index_r 的选择代码未追」已消除（§12.2 给出完整地址与语义）；region 0..5 与六个 DT 子节点名的逐项对应也已解出（§12.7）。**§12 至此无遗留推测。**

## 12.7 region 0..5 ↔ 六个名字：已解出（本节把 §12.3 的推测升级为证实）

**结论（已证实）**：`region 0..5 = strategy_ratio_range_min / _low / _mid_low / _mid / _mid_high / _high`。

**证据链**：

1. `ddrc_strategy_alloc_by_node` 里取子节点名的指针数组：`0x19b9a8 adrp x25` + `0x19b9ac add x25,x25,#0`，其重定位为 **adrp 类型 275 + add 类型 277，二者同符号、同 addend**；符号是**节符号** `st_shndx=25`（= `.rodata`），addend `0x16bc0` ⇒ 数组位于 **`.rodata+0x16bc0`**。
2. 该数组 6 个槽位的重定位（`.rela.rodata`，类型 257 = R_AARCH64_ABS64，符号节 = `.rodata.str1.1`）：

| slot | 字符串（.rodata.str1.1 偏移） | 值 |
|---|---|---|
| 0 | +0x1ee42 | `strategy_ratio_range_min` |
| 1 | +0x49d39 | `strategy_ratio_range_low` |
| 2 | +0x5e5a | `strategy_ratio_range_mid_low` |
| 3 | +0xb2145 | `strategy_ratio_range_mid` |
| 4 | +0x16494 | `strategy_ratio_range_mid_high` |
| 5 | +0x5e77 | `strategy_ratio_range_high` |

3. **V2 用另一份同内容拷贝**：`ddrc_strategy_alloc_by_node` V2 引用 `.rodata+0x16c10`（0x19c9e0 / 0x19cb40），该拷贝 6 槽逐项与上表**完全相同**（同一顺序）。两类实现的名字顺序一致 ⇒ 无论走 V1 还是 V2，region 语义相同。
4. **交叉印证（同一函数内直接按 region 取名字）**：`ddrc_strategy_init` 的日志段 0x19c414/0x19c43c 再次加载该数组（x11），并在 **0x19c450 `ldr x3, [x11, x9, lsl #3]`（x9 = region）** 取名字用于打印；`w8`（= index_t，由 `cmp w8,#3` 限界）另从 x10 的数组（4 项温度名）取。即 **region 直接被当作该 6 项数组的下标**。
5. 引用点穷举（`.rela.text` 中 adrp→`.rodata+0x16bc0` 的仅有）：`ddrc_strategy_alloc_by_node` @0x19b9a8、`ddrc_strategy_init` @0x19c414 / @0x19c43c。

**为什么先前解不出（记录以便复核）**：我第一次把 (地址, addend) 配对**错位了一格**（把 0x19b9ac 的 addend 当成了 0x19b9a8 的），加上用 addend 数值**猜所在节**——`0x16bc0` 同时也落在 `.text`（size 0x254cd0）内，于是被误判成 `.text` 里的乱码。正确做法：读 `.rela.text`，按 **adrp(275)+add(277) 同符号同 addend** 配对，并用**该符号的 `st_shndx`** 定位节（不是用 addend 猜）。**radare2 的 `pd/pxq @0x19b9a8` 对此无帮助**：ET_REL 未应用重定位，r2 在 0x19b9a8 只会看到 `adrp x25, 0`（页基址为 0），必须读重定位表。

⇒ §12.3 的「推测」标记可以去掉；§12 至此**无遗留推测**（唯一保留的是 §12.2 中 item 0x1e 的取值与 `deep_spec.ratio` 的同一性，属**强推断**，见 §12.2 首条）。
