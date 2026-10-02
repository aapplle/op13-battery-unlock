# 一加 13 vbat_uv 2800mV 项目 —— 历史探索档案

> 本文档是 [PROJECT-vbat_uv-2800.md](PROJECT-vbat_uv-2800.md) 的姊妹篇：
> 主文档只保留**当前技术栈（v10）与踩坑清单**；本文档记录 **v1~v9.2 的版本演进、
> 判死的技术路线、以及每一步的实测证据**。
> 读本文档的目的：理解「为什么是现在这个样子」，避免重走弯路。

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

### H6.6 跨版本通用性

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
