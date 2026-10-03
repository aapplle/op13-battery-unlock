# 一加 13 vbat_uv 2800mV 项目 —— 历史探索档案

> 本文档是 [PROJECT-vbat_uv-2800.md](PROJECT-vbat_uv-2800.md) 的姊妹篇：
> 主文档只保留**当前技术栈（v10.5）与踩坑速查**；本文档记录 **v1~v10.5 的完整版本演进、
> 判死的技术路线、关键逆向发现、以及每一步的实测证据**（含 v10.4/v10.5 越狱解耦修复全程）。
> 读本文档的目的：理解「为什么是现在这个样子」，避免重走弯路。
> 原始 44 章完整版存档于 [_work/v10/PROJECT-vbat_uv-2800-full-v44.md](_work/v10/PROJECT-vbat_uv-2800-full-v44.md)。

---

## H1. 版本演进总览

| 版本 | 日期 | 一句话 | 结局 |
|---|---|---|---|
| v1/v2 | 10-01 | 2 个 kprobe 改 vbat_uv 显示链 | ⚠️ 只改了显示值 |
| v3 | 10-02 07:33 | 找到真正的关机判据，hook oplus_comm_update_vbat_uv_thr | ✅ 关机电压真的变了 |
| v4 | 10-02 | 在 __exit 里调 oplus_fg_set_deep_term_volt 回写 | ❌ **kCFI panic，手机重启两次** |
| v5 | 10-02 09:13 | 新增 setter hook；restore=1 指望驱动自己回写 | ❌ 驱动根本不调用 set |
| v6 | 10-02 09:20 | profile 表：跨 ColorOS 15/16/17 | ✅ 架构定型 |
| v7 | 10-02 09:38 | no_sanitize("kcfi") 破解回写 | ✅ 回写可用 |
| v7.1 | 10-02 | 误以为「模块从不改 ADSP」，删掉按钮 | ⚠️ 结论后来被推翻 |
| v8 | 10-02 14:42 | 原值是**计算值**（读实时 DT 表），setter ABI 按 profile 分 | ✅ 恢复闭环 |
| v8.1 | 10-02 13:45 | + uv_self_write / adsp_write / adsp_read | ✅ v9 的直接前身 |
| v9~v13(旧) | 10-02 | SOC 显示层修正（chip_soc_show/ui_soc hook）| ❌ **路线判死**（H4） |
| v9(新) | 10-02 14:42 | **原生 SOC 校准**：直接写电量计 term 寄存器 | ✅ 正确路线 |
| v9.1 | 10-02 20:00 | term 解耦（ADSP=2600 模型 / 关机=2800）| ✅ 0% 段 217mV→83mV |
| v9.2 | 10-03 01:54 | late-load（越狱）模式适配 | ✅ |
| **v10** | 10-03 02:40 | 代码审查清理版（见主文档）| ✅ **当前版本** |

---

## H2. 阶段一：找错方向（v1~v2）

### H2.1 最初的误判

- 以为关机电压由 ddrc_strategy 曲线决定 → **证伪**：22 个运行时探针全程
  无任何 ddrc_strategy / deep_spec 读取。
- 以为改 dtbo 就能解决 → **证伪**：目标参数 oplus_spec,uv_adjusted 不在实时 DT 里，
  是代码内置默认值（low_volt_mv=450，2800+450=3250 就是被抬高的原因）。

### H2.2 v2 的成绩与局限

v2 用 2 个 kprobe（oplus_comm_update_vbat_uv_thr+0x30 与 vbat_uv_show+0x20）
把寄存器 w8 改成 2800。**后来证明它只改了显示值**（原档 §12.1），
但 v2 留下了三笔至今仍在用的遗产：

1. **加载前指令字校验** —— 4 个签名逐字比对，不匹配安全拒绝；
2. **跨版本实证方法** —— 三版本驱动逐一反汇编对比；
3. **手工 Module.symvers** —— CRC 由类型签名决定、跨构建稳定，可手写。

---

## H3. 阶段二：真正的关机电压（v3~v5）

### H3.1 v3：真正的关机判据

vbat_uv 有两层：chip+0x52c（纯显示缓存）与 comm_drvdata+0x76d（真实值）。
v3 hook 后者，首次实测「放电到 2833mV 才关机」（1% 从 3240mV 下移到 2833mV）。

### H3.2 v4 崩溃：两次手机重启

在 __exit 里直接调用 oplus_fg_set_deep_term_volt(dev, 3250) 回写 → **rmmod 即 panic**。
当时误判为「函数内部持锁 + ADSP glink 通信导致死锁」。**这个结论是错的**（见 H5）。

### H3.3 v5 的死路：restore=1 恢复模式

思路：开机时以 restore=1 加载，放行 getter、让 setter 写 DT 原值，
指望驱动开机流程自己调用 set。实测：

```
restore=1 开机：显示/comm 恢复 3250 ✓
禁用模块再开机：ADSP 真实值仍是 2820 ✗（驱动从不主动调用 set）
```

**教训：显示值能恢复 ≠ 硬件值能恢复。**
restore 标记文件方案就此成为死代码，直到 v10 才从脚本里删掉。

---

## H4. 阶段三：SOC 显示层修正路线判死（旧 v9~v13）

### H4.1 动机

关机电压降到 2800 后，电量计空电点仍在 3250 → 3250~2800 那 450mV 全程显示 0~1%。
尝试 hook 显示链路（chip_soc_show / oplus_comm_set_ui_soc / oplus_gki_get_ui_soc /
kretprobe 改返回值）把 SOC 重新映射。

### H4.2 判死证据（高倍率放电实测）

| 方案 | 原理 | 10W+ 放电表现 |
|---|---|---|
| 端电压映射 | 按电压查表换算 SOC | 端电压跌落 135~270mV → 误差 2~3 个 SOC 点且**跳变回弹** ❌ |
| UI SOC hook | 只改给 Android 看的数字 | 不动物量计，高低负载不一致 ❌ |

**关键认知**：SOC 是库仑计（电流对时间积分），端电压 = OCV − I×R，
受负载/温度影响巨大 —— **任何基于端电压的重映射都注定失败**。

期间还付出过一次崩溃代价：kretprobe 改返回值时碰了错寄存器 → 重启。
恢复 SOP 见原档 §22.14。

---

## H5. 阶段四：破解回写（v7~v8）

### H5.1 v4 崩溃的真正根因：kCFI 类型哈希

反汇编 v4 的 .exit.text：

```asm
+0x0f4  ldur  w16, [x19, #-4]        ; 读目标函数前的 kCFI 类型哈希
+0x100  cmp   w16, w17               ; 与「我们声明的原型」的哈希比对
+0x108  brk   #0x8233                ; 不匹配 → brk → panic
```

设备 CONFIG_CFI_CLANG=y 且 **未开 CFI_PERMISSIVE** → 函数指针调内核函数时
原型声明与真实原型哈希不一致即 panic。**与锁无关。**

解法：noinline + no_sanitize("kcfi") 跳板函数，全模块 0 个 CFI 检查。

### H5.2 v8：原值是【计算值】

深度放电次数 deep_dischg_counts 决定 term 档位：
目标电压 = term_coeff 表中「最后一条 count <= 当前次数」的电压。
COS17 实测 count=1734 → 3250（与驱动日志一致）；COS15 表结构相同但档位数值不同
（350~600 档）—— **必须读实时 DT 算，不能硬编码**。
这就是 action.sh 里 od + awk 解析大端 u32 表的由来。

### H5.3 setter ABI 的跨版本差异

| | COS16/17 | COS15 |
|---|---|---|
| 原型 | set(dev, int volt) | set(dev, int *volt) |
| profile 字段 | set_ptr=0 | set_ptr=1 |

### H5.4 「模块到底改不改 ADSP」的三次反转

1. 探针实证（原档 §17）：模块只覆盖读取值，**从不修改 ADSP 持久数据** → v7.1 删掉按钮；
2. 修正（§21）：ADSP 在**深度放电事件**时被驱动写入 → 不再绝对；
3. 决定性实验（§23.3）：deep_term_volt 就是电量计空电点，且
   **v9 起模块主动写 ADSP** → 「卸载即恢复」彻底不成立，回写流程成为卸载必需。

---

## H6. 阶段五：原生 SOC 校准（新 v9，正确路线）

### H6.1 决定性实验

假设：deep_term_volt 是电量计的空电点。
验证：写 3850mV（>电池电压 3758）→ 在线无反应；**重启后** chip_soc/rm 被钳到 0、
fcc 4388→2492 重算。结论：

1. deep_term_volt 就是 Termination Voltage ✅
2. 当时认为「只在开机时读」→ 后被 H6.3 修正
3. **不需要改 dtbo**，运行时写寄存器即可 ✅

### H6.2 钳位事故

写入值高于电池电压 → 电量计强制 DOD=100% → **回写原值 + 重启也不自愈**，
只能靠一次完整充电（rm 追上 fcc，DOD 重锚为 0）。
推论：**回写前必须先充电到 3250mV 以上** —— v10 已把该警告做进 action.sh。

### H6.3 fcc 重算触发点的两次修正

| 阶段 | 结论 | 修正依据 |
|---|---|---|
| §23 | 「只在开机时读」 | 3850 钳位实验 |
| §29 | 「满充重锚时重算」（rm 追上 fcc） | soclog 完整抓到重锚瞬间 fcc 2492→4416 |
| §40 | **「实时读取，满电状态切换即重算」** | 实验 C：运行中改 term 后，满电拔/插充电器立即触发重算，**不需要第二次重启** |

最终安装流程：**1 次重启（装模块）+ 满电状态拔插一次充电器**。

### H6.4 实测成绩

| term | fcc | 说明 |
|---|---|---|
| 3250（原厂）| 4346~4366 | |
| 2800 | 4878~4956 | +12~13.5% |
| 2600（解耦）| 4988~5032 | 0% 段从 217mV/9分钟 缩到 **83mV/0.9分钟** |

**解耦设计**：ADSP term=2600 只压电量计模型下限；
关机电压由内核 getter hook 固定 2800。两者独立。

### H6.5 跨版本通用性

解耦 5 层中 ①②③④（挂钩点签名、setter ABI、硬件命令 0x800A、shell）
三版本静态验证全过；**第 ⑤ 层（电量计固件行为）无法静态证明** ——
最坏情况只是退化为旧行为，不造成损坏。

---

## H7. 跨版本实证方法学

### H7.1 内核侧：跨 6.6.30 / 6.6.89 / 6.6.118 完全一致

| 符号 | CRC（三版本一致） |
|---|---|
| module_layout | 0x4e276f37 |
| _printk | 0x92997ed8 |
| register_kprobe | 0x0472cf3b |
| unregister_kprobe | 0xeb78b1ed |
| __stack_chk_fail | 0xf0fdf6cb |

结论：为 6.6.118 编译的模块可直接加载到 6.6.30 / 6.6.89。

### H7.2 驱动侧挂钩点结论

| Hook | COS15 | COS16 | COS17 |
|---|---|---|---|
| update_vbat_uv_thr+0x30 | ✅ | ✅ | ✅ |
| vbat_uv_show+0x20 | ✅ | ✅ | ✅ |
| vbat_uv_show+0x1c（chip 偏移） | ❌ | ❌ | ✅ → **已弃用** |
| adjust 入口 | ❌ 函数不存在 | ❌ | ✅ → **已弃用** |

---

## H8. 逆向结果速查

### H8.1 关键符号与指令偏移（oplus_chg_v2.ko）

| 符号 | 挂钩点 | 指令字 | 用途 |
|---|---|---|---|
| oplus_comm_update_vbat_uv_thr | +0x2c | 0xb9400108 (ldr w8,[x8]) | 校验 |
| 同上 | +0x30 | 0xb9000268 (str w8,[x19]) | **改 w8=2800** |
| vbat_uv_show | +0x10 | 0xaa0203e0 (mov x0,x2) | 校验 |
| 同上 | +0x20 | 0x2a0803e2 (mov w2,w8) | **改 w8=2800** |
| oplus_fg_get_deep_term_volt | COS16/17 +0xe0 | 0xb9000263 | 改 w3（profile）|
| 同上 | COS15 +0x78 | 0xb9000283 | 改 w3（profile）|
| oplus_fg_set_deep_term_volt | COS16/17 +0x34 | 0x2a0103f3 | 改 w1（profile）|
| 同上 | COS15 +0x58 | 0xb90017e9 | 改 w9（profile）|

### H8.2 关键 DT 节点 / sysfs

| 路径 | 用途 |
|---|---|
| /sys/firmware/devicetree/base/soc/oplus,mms_gauge/<电池>/deep_spec,term_coeff | term 档位表（大端 u32，12 字节/条）|
| /sys/devices/virtual/oplus_chg/common/deep_dischg_counts | 深度放电次数 |
| /sys/class/oplus_chg/battery/{vbat_uv,chip_soc,battery_rm,battery_fcc} | 电量计节点 |
| /sys/class/power_supply/battery/capacity | Android 显示电量（bind 目标）|

### H8.3 设备策略（禁超级省电）

```
键：oplus_diable_super_power_saving_mode（注意 diable 是官方拼写）
文件：/data/system/oplus_devicepolicy_data_customize.xml
调用：su 1000 -c "service call oplusdevicepolicy 1 s16 <KEY> s16 true i32 1"
读取：su 1000 -c "service call oplusdevicepolicy 4 s16 <KEY> i32 1"
（服务端 checkPermission 要求 appId==1000；COS15/16/17 jar 均已验证存在该键）
```
---

## H9. v10.3 越狱（late-load）模式适配

### H9.1 问题

越狱模式下 `post-fs-data.sh` 不执行，模块由 `late-load.sh` 在系统启动后加载。
用户实测反馈（C16 免解越狱用户截图）：

```
uv2800: 直读失败 (dev=0000000000000000 get=ffffffdcd6734928)
uv2800: 信息不全 (dev=0000000000000000 set=ffffffdcd67347ec)，无法回写
- 写入返回   : 0        <- 假成功：sysfs 写入永远返回 0
- 回写完成!
```

**根因**：模块只在 `oplus_fg_get_deep_term_volt` 入口（offset 0，取 x0）捕获 wrapper，
而驱动**只在开机调用它一次**（本机 t≈6.5s，之后 25 小时不再调用）。
越狱模式必然错过 → `uv_dev` 永远 NULL。

### H9.1b 影响范围（⚠️ 不是"全部失效"）

模块**内核 hook 不依赖 `uv_dev`**，所以越狱模式下主体功能正常（越狱用户实测反馈）：

| 功能 | 依赖 `uv_dev` | 越狱模式 |
|---|---|---|
| 关机截止电压 → 2800mV（getter hook）| ❌ | ✅ 正常（反馈"修改生效"）|
| term 强制 2800mV（setter hook）| ❌ | ✅ 正常（反馈"**fcc 相比解容前增长**"）|
| 显示 bind-mount chip_soc | ❌ | ✅ 正常 |
| 禁超级省电（设备策略）| ❌ | ✅ 正常 |
| `adsp_read/adsp_write/restore` 参数 | ✅ | ❌ **失效** |

**失效的两条后果**：① 卸载前的恢复回写写不进去；② 解耦目标 2600 写不进去，
ADSP 停在 setter hook 强制的 2800（"未解耦"）。

### H9.2 失败路线（全部实测，勿重试）

| # | 方案 | 结果 |
|---|---|---|
| 1 | 从 `vbat_uv_show+0`（入口）捕获 device | ❌ 内核崩溃 |
| 2 | 从 `vbat_uv_show+0x0c` 捕获 device | ❌ 30 秒后崩溃（拿到的是**另一个** device）|
| 3 | 伪造 wrapper `{0, device}` 传给 getter | ❌ 内核崩溃 |
| 4 | 挂钩 `oplus_fg_get_vct` / `oplus_fg_get_car_c` 入口 | ❌ 正常运行时驱动根本不调用它们 |
| 5 | 读电量计 sysfs 节点触发 | ❌ 只走 comm 层缓存 |
| 6 | 切 `input_suspend` 模拟充电状态变化 | ❌ 不触发 getter |
| 7 | 挂钩 `oplus_comm_update_vbat_uv_thr+0x10` 取 x0 | ❌ 是 comm device，非 wrapper |
| 8 | 挂钩 `oplus_gauge_term_voltage_vote_callback` 取 x1 或 `*(x1+8)` | ❌ 两者都不是 wrapper |

**关键实测数据（诊断版内核模块打印，本机 COS17）**：

```
真 wrapper        = ffffff887ab0b000
真 wrapper 的 +8  = ffffff88308ee010   <- getter 需要的 device
vbat_uv_show 的 x0= ffffff8817cc0c00   <- 完全不同的 device（一加13 双电芯）
vote x1           = ffffff880fc64080
vote *(x1+8)      = ffffff881003f000
comm_thr x0       = ffffff880fe3f800
```

### H9.3 成功解法：插拔一次充电器

实测（本机 COS17，干净越狱模拟：禁用模块 → 重启 → 手动 insmod）：

```
[  88.48] charger suspend change ...          <- 手动插拔充电器
[  90.55] charger suspend change ...
[ 100.76] uv2800: 直读 ADSP deep_term_volt = 2600 mV (rc=2600)   <- 恢复
写 3000 -> 读回 3000 OK ；写 2600 -> 读回 2600 OK
```

驱动在充电状态变化时会重新投票终止电压 → 再次调用 getter → 模块立即捕获 wrapper。

**内核模块零改动**（`uv2800.ko` md5 `0273103a`，与 v10 一致），只改脚本：
`service.sh` 后台 `adsp_retry`（15s × 240）、`action.sh` 探测+提示等待 60s、
`late-load.sh` 说明。

### H9.4 调试方法学教训

用 `rmmod` + `insmod` 模拟越狱模式会**假性崩溃**（热卸载 kprobe 不安全），
必须用「禁用模块（`/data/adb/modules/uv2800/disable`）→ 重启 → 手动 `insmod`」
才能复现真实越狱路径。

### H9.5 ⚠️ 越狱模式下「解耦」失效（影响 SOC/fcc，**不影响关机**）

⚠️ **先澄清机制**：**0% 不会导致关机** —— 关机由 `vbat_uv`（=2800mV）决定，
来源是内核 getter hook，**越狱模式下完全正常** ✅。SOC 显示（bind-mount chip_soc）**只影响 UI**。

所以越狱模式下**关机电压 2800mV 真实生效**，手机会一直放到 2800mV 才关机 ✅。

**真正失效的是「解耦」**：

| 模式 | ADSP term | 模型空电点 | 后果 |
|---|---|---|---|
| 标准模式 | 2600（service.sh 写）| ≈2800 | SOC/fcc 按解耦后模型算 ✅ |
| **越狱模式** | **2800**（setter hook 强制）| ≈3000 | SOC/fcc 仍偏保守 ✗（**不影响关机**）|

**根因**：`uv_term_set` hook 强制 `UV_TARGET_MV`（2800），而解耦目标 2600 是
service.sh 通过 `adsp_write` 写的（依赖 `uv_dev`，越狱下失效）。
所以越狱模式 fcc 增长 ✅ 但模型下限没压下去 ✗。

**建议修法**：把 `uv_term_set` 的强制值改为可配置 module_param（默认 2600）——
纯寄存器改写、**不需要 `uv_dev`**，越狱下驱动写一次 term 即生效。
注意 `uv_term_get`（决定关机电压）必须保持 2800 不变。

**验证方法**：越狱下确认 `adsp_read` == 2600（或 fcc 升到 ~5000），即解耦生效。


---

## H10. v10.4/v10.5 越狱解耦修复（逆向 + 实测完整记录）

### H10.1 v10.4 内核：setter 强制值参数化

把 `uv_term_set` 的固定 `UV_TARGET_MV`(2800) 改为 `module_param uv_adsp_force_mv`（默认 2600）。
依据（COS15/16/17 反汇编）：`oplus_gauge_term_voltage_vote_callback` 内部 `ldr x0,[x21,#0x30]`
取 wrapper 后直接 `bl oplus_mms_gauge_set_deep_term_volt` → 函数表 → `oplus_fg_set_deep_term_volt`
（我们 hook 的地方）。**vote 一触发即走 setter，不依赖 `uv_dev`。**

**语义分离**：`uv_term_get`（关机电压）保持 2800 不变；`uv_term_set`（模型下限）强制 `adsp_force`。

### H10.2 关键逆向发现：vote 是事件驱动，不是定时

这是本轮最重要的认知修正（曾误判为「零操作自治」）：

- `GAUGE_TERM_VOLTAGE` votable 的 vote client 是 `DEEP_COUNT_VOTER`，vote 方是
  `oplus_gauge_get_ddrc_status`（按深度放电次数查 DT `term_coeff` 档位表）。
- vote 值本身**极少变化**（档位跨度几百~上千次循环）；vote 框架只在 effective 值变化时调 callback。
- 充电状态**稳定**时 vote 值不变 → setter 不走 → 解耦不触发。
- **只有「充电状态变化」（最可靠=插拔充电器）或「深度放电跨档」（极罕见）才触发 vote。**

实测（COS17，模拟越狱：禁用模块→重启→手动 insmod）：

```
insmod 后  : adsp_read=0（uv_dev 未捕获）
插拔充电器 → vote 触发
t=778s     : 从 getter 捕获 wrapper=ffffff887a616800
最终       : adsp_force=2600  ADSP=2600  vbat_uv=2800  fcc=5010（已解耦）
```

**与 v10.3 的关系**：触发条件完全相同（都需插拔一次），区别是：

- v10.3：插拔后靠 `service.sh` 后台重试 `adsp_write`（依赖 `uv_dev`）写 2600；
- v10.4/10.5：插拔后靠 vote→setter 直接强制 2600（**不依赖 `uv_dev`**），
  且 setter 默认值由「拦截成 2800」改为「强制成 2600」。

### H10.3 已废弃的方案 B：work 函数反推 chip→wrapper

曾新增第 6 个 kprobe 挂钩周期性 work 函数入口，`chip = x0 - work_chipoff`、`wrapper = *chip`。
三版本 work 偏移静态核对（自洽验证通过）：

| 版本 | work 函数 | chip = x0 - |
|---|---|---|
| COS17 | oplus_mms_gauge_set_deep_term_volt_work | 0x638 |
| COS16 | oplus_mms_gauge_sili_term_volt_effect_check_work | 0x558 |
| COS15 | oplus_mms_gauge_sili_term_volt_effect_check_work | 0x4b8 |

**实测证明冗余**：vote callback 触发时驱动在同一流程里【同步】调用 getter
（`kp_term_entry` 立即捕获），而 work 是被 `queue_delayed_work`【异步】排的
（vote callback 里 `mov w3,#0x1f4`=500ms 延迟）—— **getter 捕获永远先命中**，
work 捕获拿不到任何 getter 给不了的能力，反而多一个 hook 点和内存解引用风险。
**已从 v10.4 移除**，回归 5 个 hook。

### H10.4 v10.5 脚本精简（用户触点优化）

1. **action.sh 修超时假成功**：v10.3 就绪等待 60s 超时后仍无条件 `echo $TARGET > restore`，
   sysfs 写永远返回 0 → 结尾照样打「回写完成！」（假成功）。v10.5 改为超时 `exit 1` 硬中止
   +「电量计未被改动」提示。插拔检测只在 `KSU_LATE_LOAD=1` 启用，标准用户零打扰。
2. **service.sh 删 1 小时 adsp_retry**：vote 触发只能靠插拔，后台死等 1 小时无意义
   （用户不插拔永远超时，插拔了前台/action 路径也能处理）。
3. **adsp_target→adsp_force 同步**：日常解耦不再用 `adsp_write`（依赖 `uv_dev`），
   改为把 `adsp_target` 值写入内核 `adsp_force` 参数。`adsp_write` 内核参数保留作诊断/手动调试。
4. **新增 customize.sh**（安装时执行、用户可见）：仅越狱模式提示插拔 + 无时间限制说明。
5. **文案补全**：module.prop description 标注越狱模式插拔要求。

### H10.5 参数职责最终厘清

| 参数 | 职责 | 依赖 uv_dev |
|---|---|---|
| adsp_force | 日常解耦（setter hook 强制值，默认 2600）| ❌ |
| adsp_read | 就绪探测 / 解耦验证（直读真实值）| ✅ |
| adsp_write | 诊断 / 手动调试 | ✅ |
| restore | 卸载回写原值（+ 永久放行 hook）| ✅ |

**结论**：日常解耦与设备指针彻底解耦；`uv_dev` 只在「卸载回写原值」时必需，
而那本来就需要插拔一次充电器（vote 触发 getter 捕获）。

### H10.6 「自定义关机电压」评估（未实现）

技术上可行（照 `adsp_force` 模式把 `uv_term_get` 的 2800 也做成参数 `shutdown_mv`），
但有硬件风险：2800mV 是硅碳负极物理放电下限，改低过放损坏电池、改错触发 DOD 钳位
不自愈（需充满一次恢复）；且 shutdown 必须 ≥ ADSP term 并留余量，否则 SOC/关机行为异常。
若实现需：范围钳制 2700~3400 + 强制 `shutdown > adsp_force` 校验 + 默认 2800 + 文档标风险。
**判断：收益小于风险，默认不开放。**