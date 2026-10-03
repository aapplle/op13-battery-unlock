# 一加 13 vbat_uv 2800mV 项目文档（当前技术栈 v10）

> 目标：把一加 13 的关机截止电压 3250mV → **2800mV**，并让电量计**原生**按新空电点计算 SOC。
> 形态：1 个内核模块（5 个 kprobe，28KB）+ 1 个 KernelSU 模块。**不改任何分区、不刷 dtbo。**
> 版本演进、判死路线与实测证据 → [PROJECT-history.md](PROJECT-history.md)
> 最后更新：2026-10-03（v10 实机验证通过）

---

## 0. TL;DR

```
/sys/class/oplus_chg/battery/vbat_uv  = 3250mV  →  2800mV   （内核 kprobe 强制）
ADSP deep_term_volt                   = 3250mV  →  2600mV   （电量计模型下限，解耦）
fcc                                   = 4346mAh →  ~5032mAh （电量计原生重算，+15.8%）
显示                                  = bind-mount chip_soc → capacity（去官方平滑滞后）
超级省电                              = 设备策略禁用低电量强制进入
卸载                                  = 先点「执行」按钮回写原值 → 删除模块 → 重启
```

四条最重要的结论：

1. **关机电压**与**电量计模型**是两条独立的链 —— 前者由内核 getter hook 固定 2800，
   后者由 ADSP term 寄存器控制，两者完全解耦。
2. **显示层 SOC 修正路线已判死**（端电压受负载影响 135~270mV，映射必然跳变），
   唯一正确的做法是让电量计**原生**重算 fcc。
3. 电量计**实时读取** term 寄存器，但 fcc 重算需要一次**满电状态切换**
   （充满 / 满电拔插充电器），不需要第二次重启。
4. 跨 ColorOS 15/16/17 × 内核 6.6.30/89/118 通用（逐层静态+真机实证），
   支持 KernelSU late-load（越狱）模式。

---

## 1. 设备与环境

| 项目 | 内容 |
|---|---|
| 机型 | OnePlus 13（PJZ110），硅碳负极电池（可放电到 2800mV）|
| 已适配系统 | ColorOS 17.0.0.101（真机）/ 16.0.0.212 / 15.0.0.126（静态验证）|
| 已适配内核 | 6.6.118 / 6.6.89 / 6.6.30（android15-8 GKI）|
| Root | KernelSU ksud 3.3.0（标准 + late-load 模式）|
| 目标节点 | /sys/class/oplus_chg/battery/vbat_uv（只读）|

---

## 2. 技术架构（v10）

### 2.1 五层解耦设计

```
① 内核 getter hook   → oplus_fg_get_deep_term_volt 内部：驱动读到的 term 固定为 2800
                        【这决定关机电压】
② 内核 setter hook   → oplus_fg_set_deep_term_volt 内部：阻止驱动把 term 写回电量计
                        【没有它，驱动会把 ADSP 里的 2600 覆盖回 3250】
③ ADSP 写入          → service.sh 经 adsp_write 写 2600（命令 0x800A）
                        【这只影响电量计模型下限，不影响关机电压】
④ 显示层             → bind-mount chip_soc → capacity（VFS 级，去平滑滞后）
⑤ 策略层             → oplusdevicepolicy 禁超级省电（用户态，与内核无关）
```

### 2.2 内核模块（uv2800_v10.c，5 个 kprobe）

| Hook | 挂钩点 | 动作 | 用途 |
|---|---|---|---|
| kp_get | oplus_comm_update_vbat_uv_thr+0x30 | w8=2800 | 关机阈值（comm 层）|
| kp_show | vbat_uv_show+0x20 | w8=2800 | sysfs 显示 |
| kp_term_get | oplus_fg_get_deep_term_volt+get_off | reg=2800 | ① getter 强制 |
| kp_term_set | oplus_fg_set_deep_term_volt+set_off | reg=2800 | ② setter 拦截 |
| kp_term_entry | oplus_fg_get_deep_term_volt+0 | 捕获 x0=dev | 供回写复用 dev |

**profile 表**（运行时指令字探测自动选择）：

| | get_off / get_reg | set_off / set_reg | setter ABI |
|---|---|---|---|
| ColorOS 16/17 | 0xe0 / w3 | 0x34 / w1 | (dev, int) |
| ColorOS 15 | 0x78 / w3 | 0x58 / w9 | (dev, int*) |

**安全机制**：

- 加载前 4 条指令字硬校验，不匹配 **拒绝加载**（不注册 hook、不崩溃）；
- profile 匹配失败仅降级（只注册 2 个显示 hook）；
- 间接调内核函数全部走 noinline + no_sanitize("kcfi") 跳板（CONFIG_CFI_CLANG=y 必须）；
- 回写电压范围校验 2000~5000mV；uv_dev 未捕获前拒绝调用。

**三个模块参数**（/sys/module/uv2800/parameters/）：

| 参数 | 写 | 读 |
|---|---|---|
| adsp_read | 任意值 → 触发直读 | ADSP 当前 term（绕过 hook 的真实值）|
| adsp_write | 电压值 → 写 ADSP，**不改变**强制状态 | 最近一次写入值 |
| restore | 电压值 → 写 ADSP + **永久放行所有 hook**（恢复模式）| 最近一次回写值 |

### 2.3 KernelSU 模块结构

```
/data/adb/modules/uv2800/
├── module.prop        version=10.0
├── post-fs-data.sh    标准启动：等 oplus_chg_v2（≤30s）→ insmod
├── late-load.sh       越狱模式：已加载则跳过（防重复 insmod 重置 uv_dev）
├── service.sh         ADSP 写入（值不同才写）+ bind-mount + 设备策略【完全幂等】
├── action.sh          「执行」按钮：读实时 DT 算原值回写 + 恢复策略 + 恢复显示
├── uninstall.sh       恢复设备策略文件（ADSP 无法在此回写，有诚实提示）
└── uv2800.ko          28568 字节
```

**备份目录 /data/adb/uv2800_backup/**（放在模块外，卸载后仍存在）：

| 文件 | 用途 |
|---|---|
| adsp_orig.txt | 首次写入前备份的电量计原始 term（如 3250）|
| adsp_target | ADSP 目标值（默认 2800；写 2600 启用解耦）|
| applied / orig_state / devicepolicy_orig.xml | 设备策略备份（只备一次）|
| skip | 点过「执行」按钮后打上 → 不再自动应用策略（重装前需 rm）|
| no_adsp_write / no_real_soc | 测试开关：分别禁用 ADSP 写入 / bind-mount |

### 2.4 action.sh 的原值计算（核心设计）

回写目标**不是硬编码 3250**，而是实时计算：

```
目标电压 = term_coeff 表中「最后一条 count <= 当前 deep_dischg_counts」的电压
```

- DT 表：/sys/firmware/devicetree/base/soc/oplus,mms_gauge/<电池>/deep_spec,term_coeff
  （大端 u32，每条 12 字节：voltage, count, reserved）
- COS17 实测 count=1734 → 3250 ✅；COS15 表结构相同但档位不同 → 必须实时算
- 解析用 od + awk（纯 POSIX，Android toybox 可跑）
- **UV2800_DRYRUN=1 sh action.sh** 可试运行（只算不写）

---

## 3. 使用与运维 SOP

### 3.1 首次安装

```sh
1) KernelSU 刷入模块 → 重启                     ← 唯一需要的一次重启
2) 模块在开机后自动写入 ADSP term（2600 或 2800）
3) 触发一次满电状态切换（三选一）：
     · 充满一次；· SOC=100 时拔充电器；· SOC=100 时插充电器
4) fcc 原生重算 ✅ 完全生效
```

### 3.2 验证是否生效

```sh
cat /sys/class/oplus_chg/battery/vbat_uv                 # 2800
P=/sys/module/uv2800/parameters
echo 1 > $P/adsp_read; cat $P/adsp_read                # 2600（或 2800）
cat /sys/class/oplus_chg/battery/battery_fcc             # ~5000（解容后）
grep -c capacity /proc/mounts                            # ≥1（bind 生效）
dmesg | grep uv2800:                                     # v10 ready, 5 个 hook
```

### 3.3 卸载（顺序不能错）

```sh
1) 【必须】电量充足（>50%，电压 >3250mV）时点 KernelSU 模块的「执行」按钮
      → 自动算原值回写 + 恢复超级省电 + 恢复官方平滑显示
      ⚠️ 低电压回写会让电量计进入钳位态（SOC 卡 0%，需充满一次才恢复）
2) 删除/禁用模块，重启
3) 验证：cat /sys/class/oplus_chg/battery/vbat_uv   → 应显示原值（如 3250）
```

**如果只删模块不点按钮**：关机电压恢复 3250，但 ADSP 里仍是 2600/2800 →
电量计空电点低于关机点，**还有百分之几就关机**。恢复方法：重装模块 → 点按钮。

### 3.4 重新启用模块

```sh
rm /data/adb/uv2800_backup/skip     # 否则「禁止超级省电」不会重新应用
```

### 3.5 从 ROM 提取 oplus_chg_v2.ko（适配新版本时）

```sh
# 在 vendor_dlkm.img（ext4），不在 vendor.img
# 路线 A：OTA payload → payload-dumper-go
# 路线 B：super.img → lpunpack
# 路线 C：真机 adb exec-out su -c "cat /vendor_dlkm/lib/modules/oplus_chg_v2.ko" > oplus_chg_v2.ko
# 9008 售后包的 sparse 镜像需先转 raw 再挂载
```

---

## 4. 踩坑清单（血泪版，按主题分类）

### 4.1 内核构建 🔴

| # | 坑 | 教训 |
|---|---|---|
| 1 | **kCFI 缺失 → 手机重启两次** | 函数指针调内核函数必须 no_sanitize("kcfi")；先验证编译命令有 -fsanitize=kcfi 和 -ffixed-x18 |
| 2 | olddefconfig 静默丢弃配置 | 改完 .config 必须检查关键项还在 |
| 3 | include/config/auto.conf 不自动重新生成 | rm -f include/config/auto.conf* 再 syncconfig |
| 4 | 公开内核源码树缺厂商 Kconfig | 打桩缺失 Kconfig 才能 make |
| 5 | vermagic 的 release 段不校验 | 带 __versions 时只比第一个空格后的部分 → 6.6.118 编译的 ko 可加载 6.6.30/89 |
| 6 | **modversions CRC 跨构建稳定** | CRC 由类型签名决定（genksyms）→ 可手写 Module.symvers；新符号可用「预处理内核源 + genksyms」推导（v10 的 kstrtoint 即如此）|
| 12 | ROCm 的 clang 没有 AArch64 后端 | 用系统 clang-18 + ROCm 的 llvm 二进制工具拼工具链 |
| 13 | 手写 Module.symvers 要 5 个字段 | 0xCRC\t符号\tvmlinux\tEXPORT_SYMBOL\t（最后必须有 TAB）|
| 14 | 手动 ld.lld 链接的模块不可靠 | 走内核 Kbuild（make M=）|
| 16 | 局部 struct kprobe 引入额外符号 | kprobe 全部做成文件级 static |

### 4.2 运行时探测 🟠

| # | 坑 | 教训 |
|---|---|---|
| 7 | tracefs kprobe 必须显式 enable | echo 1 > events/kprobes/<名>/enable，光注册不 enable 没数据 |
| 8 | tracefs 事件洪水淹没探针 | 先 tracing_on=0、清空 kprobe_events 再逐个加 |
| 9 | kptr_restrict=2 时 kallsyms 地址全 0 | 用 register_kprobe 解析符号拿地址（模块内不受限）|
| 10 | **sysfs 显示值 ≠ 真实值** | vbat_uv 有显示缓存层；验证要看驱动内部口径（dmesg/真实寄存器）|
| 11 | 改 chip 字段会留残留 | 只改纯函数/寄存器，不碰结构体 |

### 4.3 Android/脚本 🟡

| # | 坑 | 教训 |
|---|---|---|
| 15 | SELinux 上下文 | 模块文件 chcon -R u:object_r:system_file:s0；脚本用 LF 换行 |
| 17 | Android toybox grep 不支持 BRE \| 交替 | 验证命令用 grep -oE（ERE）——曾因此误判「策略没生效」|
| 18 | 9008 包镜像是 sparse 格式 | 先 sparse2raw 再挂载 |
| 19 | **bind-mount 的挂载点记录的是解析后真实路径** | /proc/mounts 探测 $CAP 不可靠（v10 实测叠 8 层）→ 幂等用「先循环 umount 再重 bind」|
| 20 | **adb shell 管道里 \| 会被外层解释** | 嵌套引号陷阱；验证类命令直接读全量输出再本地过滤 |
| 21 | KSU_LATE_LOAD 模拟 ≠ 真实越狱路径 | 模拟能验证脚本幂等，但 mount namespace 等内核语义差异无法覆盖；nsenter 分支需真越狱环境验证 |

### 4.4 电量计行为（实测）🔴

| # | 现象 | 结论 |
|---|---|---|
| 22 | 写入 term > 电池电压 → 钳位且**不自愈** | DOD=100% 只能靠充满一次重锚；回写前必须先充到 3250mV 以上 |
| 23 | UI 显示 100% ≠ 电量计计满 | 重锚点在 rm 追上 fcc（CV 阶段末尾之后），可能晚于 UI 100% 数分钟 |
| 24 | fcc 重算触发 = **满电状态切换**，不是重启 | 运行中改 term 后满电拔/插充电器即触发（§40 实验 C）|
| 25 | 高倍率放电后**当次** FCC 偏小 | 电量计固有特性，1 次低功耗循环可校准回 |

---

## 5. 跨版本兼容性

### 5.1 验证矩阵

| 层 | COS17 | COS16 | COS15 | 方法 |
|---|---|---|---|---|
| 内核符号 CRC | ✅ | ✅ | ✅ | 三版本 Module.symvers 实测一致 |
| 显示链挂钩点 | ✅ | ✅ | ✅ | 归一化反汇编逐指令比对 |
| getter/setter 挂钩点 | ✅ | ✅ | ✅ | profile 表 + 指令字签名 |
| setter ABI | (dev,int) | (dev,int) | (dev,int*) | profile set_ptr |
| 硬件命令 0x800A | ✅ | ✅ | ✅ | 反汇编确认（寄存器差异已覆盖）|
| 设备策略键 | ✅ 真机 | ✅ jar | ✅ jar | oplus-services.jar grep |
| 电量计 term→fcc 行为 | ✅ 真机 | ⚠️ 未验证 | ⚠️ 未验证 | ADSP 固件无法静态分析；最坏退化为旧行为，不损坏 |

### 5.2 失败安全

| 场景 | 行为 |
|---|---|
| 驱动更新导致指令字不匹配 | init 拒绝加载，手机正常开机（无 hook）|
| profile 不匹配 | 只注册 2 个显示 hook，ADSP 功能禁用 |
| KMI 变化（CRC 不匹配）| insmod 被内核明确拒绝 |
| late-load 下 nsenter 不可用 | 回退当前命名空间 bind（v9.2 行为）|

---

## 6. 风险与限制

| 风险 | 说明 | 缓解 |
|---|---|---|
| 电池寿命 | 2800mV 是硅碳负极放电下限，长期深度放电加速老化 | 可只改 ADSP 解容、不常用到低电压段 |
| 低电压回写 | vbat < 回写目标时电量计钳位（坑 22）| action.sh 已加 <3300mV 醒目警告 |
| 电量计固件行为（COS15/16）| term→fcc 重算未经真机验证 | 首次放电观察 0% 落点即可确认 |
| 真实越狱模式 | nsenter 分支只经模拟验证（本机 GhostLock 已修复）| 最坏回退 v9.2 行为 |

---

## 7. 文件索引

### 本仓库

| 路径 | 说明 |
|---|---|
| [README.md](README.md) | 项目介绍、安装与卸载 SOP |
| [PROJECT-vbat_uv-2800.md](PROJECT-vbat_uv-2800.md) | 本文档（当前技术栈 + 踩坑清单）|
| [PROJECT-history.md](PROJECT-history.md) | v1~v9.2 演进史、判死路线、实测证据 |
| [_work/ksu-module/uv2800/](_work/ksu-module/uv2800/) | **当前模块打包源（v10）** |
| [_work/ksu-module/一加13解容-v10.2.zip](_work/ksu-module/一加13解容-v10.2.zip) | v10 发布包（md5 d657a767）|
| [_work/ksu-module/uv2800.zip](_work/ksu-module/uv2800.zip) | v9.2 发布包（保留）|
| [_work/uv2800/uv2800_v10.c](_work/uv2800/uv2800_v10.c) | 当前内核源码 |
| [_work/uv2800/uv2800_v10.ko](_work/uv2800/uv2800_v10.ko) | 当前 ko（28568 字节）|
| [_work/uv2800/uv2800_v9.c](_work/uv2800/uv2800_v9.c) | 上一版源码（保留）|
| [_work/uv2800/Makefile](_work/uv2800/Makefile) | 构建入口 |
| [_work/uv2800/archive_deprecated/](_work/uv2800/archive_deprecated/) | v3~v13 全部源码与 ko |
| [_work/uv2800/docs/](_work/uv2800/docs/) | 实测图表（放电曲线 / 对比图）|

> 开发过程中的逆向工具、设备端测试脚本、原始日志与厂商 ko 样本**未随仓库发布**
> （日志含隐私信息，厂商二进制有版权）。

### 设备上

| 路径 | 说明 |
|---|---|
| /data/adb/modules/uv2800/ | 当前安装模块（v10.0）|
| /data/adb/uv2800_backup/ | 备份与开关（见 §2.3）|
| /sys/module/uv2800/parameters/ | adsp_read / adsp_write / restore |

### 构建环境

需要一个与目标内核匹配的源码树与工具链（可放在任意临时目录）。
关键要求见 §4.1「内核构建」与 README 的「构建」一节。
