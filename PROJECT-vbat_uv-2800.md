# 一加 13 vbat_uv 2800mV 项目文档（当前技术栈 v10.6）

> 目标：把一加 13 的关机截止电压 3250mV → **2800mV**，并让电量计**原生**按新空电点计算 SOC。
> 形态：1 个内核模块（5 个 kprobe，30KB）+ 1 个 KernelSU 模块。**不改任何分区、不刷 dtbo。**
> 版本演进、判死路线、实测证据 → [PROJECT-history.md](PROJECT-history.md)
> 最后更新：2026-10-03（v10.6：越狱模式解耦修复 + 脚本精简）

---

## 0. TL;DR

```
/sys/class/oplus_chg/battery/vbat_uv  = 3250mV  →  2800mV   （内核 getter hook 强制）
ADSP deep_term_volt                   = 3250mV  →  2600mV   （service.sh 经 adsp_write 写入，解耦）
fcc                                   = 4346mAh →  ~5032mAh （电量计原生重算，+15.8%）
显示                                  = bind-mount chip_soc → capacity（去官方平滑滞后）
超级省电                              = 设备策略禁用低电量强制进入
卸载                                  = 先点「执行」按钮回写原值 → 删除模块 → 重启
```

五条最重要的结论：

1. **关机电压**与**电量计模型**是两条独立的链 —— 前者由内核 getter hook 固定 2800，
   后者由 service.sh 经 `adsp_write` 主动写 2600，两者完全解耦。
2. **显示层 SOC 修正路线已判死**（端电压受负载影响 135~270mV，映射必然跳变），
   唯一正确的做法是让电量计**原生**重算 fcc。
3. 电量计**实时读取** term 寄存器，但 fcc 重算需要一次**满电状态切换**
   （充满 / 满电拔插充电器），不需要第二次重启。
4. 跨 ColorOS 15/16/17 × 内核 6.6.30/89/118 通用（逐层静态+真机实证）。
5. **越狱（late-load）模式**：模块开机后才加载，错过开机 vote，需**插拔一次充电器**
   触发 vote —— 同时完成 ① 解耦写入（setter 强制 2600，不依赖设备指针）② 回写指针捕获。
   **无时间限制**，不插拔不影响关机保护（getter hook 2800 已生效），只是解耦/回写未就绪。

---

## 1. 设备与环境

| 项目 | 内容 |
|---|---|
| 机型 | OnePlus 13（PJZ110），硅碳负极电池（可放电到 2800mV）|
| 已适配系统 | ColorOS 17.0.0.101（真机）/ 16.0.0.212 / 15.0.0.126（静态验证）|
| 已适配内核 | 6.6.118 / 6.6.89 / 6.6.30（android15-8 GKI）|
| Root | KernelSU ksud 3.3.0（标准 built-in/lkm + late-load 越狱模式）|
| 目标节点 | /sys/class/oplus_chg/battery/vbat_uv（只读）|

---

## 2. 技术架构（v10.6）

### 2.1 五层解耦设计

```
① 内核 getter hook   → oplus_fg_get_deep_term_volt 内部：驱动读到的 term 固定为 2800
                        【这决定关机电压】
② 内核 setter hook   → oplus_fg_set_deep_term_volt 内部：阻止驱动把 term 覆盖回 3250
                        【防御性：没有它，驱动 vote 时会把 ADSP 里的 2600 覆盖回 3250】
③ 解耦写入           → service.sh 经 adsp_write【主动】写 2600（硬件命令 0x800A）
                        【这只影响电量计模型下限，不影响关机电压】
④ 显示层             → bind-mount chip_soc → capacity（VFS 级，去平滑滞后）
⑤ 策略层             → oplusdevicepolicy 禁超级省电（用户态，与内核无关）
```

**★ 解耦写入的正确机制（v10.6 实测修正）**：

- 解耦写入**唯一可靠路径**是模块通过 `adsp_write` **主动**调用
  `oplus_fg_set_deep_term_volt(uv_dev, 2600)`。`adsp_write` 本身**两种模式都可用**，
  唯一前提是 `uv_dev` 已捕获。
- setter hook（②）是**被动拦截**，不能用作解耦写入：驱动只在「vote 目标 ≠ 当前 ADSP」
  时才调 setter 写 term，日常值相同驱动不写 → hook 不触发。（v10.4/v10.5 曾误用
  `adsp_force` 作解耦路径，实测两种模式均无效，已废弃并归档。）

### 2.2 内核模块（uv2800_v10.c，5 个 kprobe）

| Hook | 挂钩点 | 动作 | 用途 |
|---|---|---|---|
| kp_get | oplus_comm_update_vbat_uv_thr+0x30 | w8=2800 | 关机阈值（comm 层）|
| kp_show | vbat_uv_show+0x20 | w8=2800 | sysfs 显示 |
| kp_term_get | oplus_fg_get_deep_term_volt+get_off | reg=2800 | ① getter 强制（关机电压）|
| kp_term_set | oplus_fg_set_deep_term_volt+set_off | reg=2800 | ② setter 拦截（防驱动覆盖）|
| kp_term_entry | oplus_fg_get_deep_term_volt+0 | 捕获 x0=dev | 供 adsp_write/restore 复用 dev |

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

| 参数 | 写 | 读 | 依赖 uv_dev |
|---|---|---|---|
| adsp_read | 任意值 → 触发直读 | ADSP 当前 term（绕过 hook 的真实值）| ✅ |
| adsp_write | 电压值 → 写 ADSP（**解耦写入主路径**，不改变强制状态）| 最近写入值 | ✅ |
| restore | 电压值 → 写 ADSP + 永久放行所有 hook（卸载恢复）| 最近回写值 | ✅ |

> **参数职责**：`adsp_write` 是解耦写入主路径（service.sh 用它写 2600）；
> `adsp_read` 做就绪探测/解耦验证；`restore` 专司卸载回写。三者都需 `uv_dev` 已捕获。

### 2.3 KernelSU 模块结构

```
/data/adb/modules/uv2800/
├── module.prop        version=10.6
├── customize.sh       安装时执行（用户可见）：仅越狱模式提示「插拔一次充电器」
├── post-fs-data.sh    标准启动：等 oplus_chg_v2（≤30s）→ insmod
├── late-load.sh       越狱模式：已加载则跳过（防重复 insmod 重置 uv_dev）
├── service.sh         adsp_write 解耦写入 + 越狱 adsp_retry 补写 + bind-mount + 设备策略【完全幂等】
├── action.sh          「执行」按钮：读实时 DT 算原值回写（越狱模式先检测插拔）
├── uninstall.sh       恢复设备策略文件（ADSP 无法在此回写，有诚实提示）
└── uv2800.ko          v10 内核（28568 字节，5 个 kprobe）
```

**备份目录 /data/adb/uv2800_backup/**（放在模块外，卸载后仍存在）：

| 文件 | 用途 |
|---|---|
| adsp_orig.txt | 首次写入前备份的电量计原始 term（如 3250）—— **action.sh 回写的第一取值来源** |
| adsp_target | 解耦目标值（默认 2600），service.sh 经 adsp_write 写入；可手改（2800=不解耦/3000=保守）|
| applied / orig_state / devicepolicy_orig.xml | 设备策略备份（只备一次）|
| skip | 点过「执行」按钮后打上 → 不再自动应用策略（重装前需 rm）|
| no_adsp_write / no_real_soc | 测试开关：分别禁用解耦同步 / bind-mount |

### 2.4 action.sh 的原值计算（两级取值）

回写目标**不是硬编码 3250**，按优先级取：

```
① $BK/adsp_orig.txt（首次写入前 service.sh 备份的真实值）
   —— 与 ColorOS 版本无关，就是驱动自己算出的原值，最可靠
② 兜底：DT 表实时计算
   目标电压 = term_coeff 表中「最后一条 count <= 当前 deep_dischg_counts」的电压
   （count 小于首档时取第一条电压，不再判失败）
```

**为什么 ① 优先**（C16 实测教训）：C16 表档位从 800 起，count<800 时纯查表失败；
且同版本 DT 存在多个表变体（dtbo 不同 overlay entry），查表结果不唯一。
**只有「首次写入前的备份值」是唯一权威原值。**

解析用 od + awk（纯 POSIX，Android toybox 可跑）；
**UV2800_DRYRUN=1 sh action.sh** 试运行（只算不写，会打印取值来源）。

---

## 3. 越狱（late-load）模式：限制与解法

KernelSU 越狱模式下 `post-fs-data.sh` 不执行，模块由 `late-load.sh` 在系统完全启动后加载。

### 3.1 影响范围（⚠️ 不是"全部失效"）

模块的**内核 hook 不依赖 `uv_dev`**，所以越狱模式下**主体功能正常**：

| 功能 | 依赖 uv_dev | 越狱模式 |
|---|---|---|
| 关机截止电压 → 2800mV（getter hook）| ❌ | ✅ 正常 |
| setter 拦截（防驱动覆盖 2600）| ❌ | ✅ 正常 |
| 显示 bind-mount chip_soc → capacity | ❌ | ✅ 正常 |
| 禁超级省电（设备策略）| ❌ | ✅ 正常 |
| **解耦写 2600**（adsp_write）| ✅ | ❌ uv_dev 未捕获前写不进 |
| **卸载回写原值**（restore）| ✅ | ❌ 需先捕获 uv_dev |

### 3.2 根因与解法

**根因不是 `adsp_write` 不可用**（v10.6 实测修正此前的错误结论）——`adsp_write` 两种模式
都能正常写 ADSP，唯一前提是 `uv_dev` 已捕获。越狱模式的真正问题是：

驱动**开机时 vote 一次**终止电压（此时调 getter），`kp_term_entry` 在那一刻捕获 `uv_dev`。
越狱模块加载太晚错过开机那次 vote → `uv_dev` 永远 NULL → `adsp_write`/`restore` 因缺指针写不进。

而 vote 是**事件驱动**——只在「充电状态变化」或「深度放电跨档」（极罕见）时再触发。

**解法：插拔一次充电器**（最可靠的 vote 触发方式），触发 getter → `kp_term_entry` 捕获
`uv_dev` → 之后 `adsp_write`/`restore` 全部可用：

1. vote → getter 调用 → `kp_term_entry` 捕获 `uv_dev`；
2. `service.sh` 的 `adsp_retry` 后台检测到 `uv_dev` 就绪后，**主动 `adsp_write` 写 2600**
   → **解耦生效**（`adsp_retry` 是必要的，v10.5 误删已恢复）；
3. `uv_dev` 一旦捕获便持久有效，之后 `adsp_write` 想写就写，**无需再插拔**。

**★ 无时间限制**：vote 是事件触发不是定时器，任意时刻插拔均有效；不插拔不影响关机保护
（getter hook 固定 2800 已生效），只是解耦与回写暂不就绪。

**用户触点提示**：

- **customize.sh**（安装时，用户可见）：仅 `KSU_LATE_LOAD=1` 时提示插拔 + 无时间限制说明；
- **action.sh**（点「执行」时）：仅越狱模式先检测就绪，未就绪提示插拔并等 60s，**超时硬中止**
  （不再像 v10.3 那样假成功）；
- **module.prop** description：标注「越狱模式刷入后及卸载前需各插拔一次充电器」。

### 3.3 已排除的方案（均实测/逆向排除，勿重试）

| 方案 | 结果 |
|---|---|
| 从 vbat_uv_show 入口 / +0x0c 捕获 device | ❌ 内核崩溃（一加13双电芯，拿到的是另一个 device）|
| 伪造 wrapper {0, device} 传给 getter | ❌ 内核崩溃（device 不对）|
| 挂钩 oplus_fg_get_vct / get_car_c 入口 | ❌ 正常运行时驱动根本不调用 |
| 读电量计 sysfs 节点触发 | ❌ 只走 comm 层缓存 |
| 切 input_suspend 模拟充电变化 | ❌ 不触发 getter（必须真实插拔）|
| work 函数反推 chip→wrapper（v10.4 曾实现）| ❌ 冗余：vote 触发时 getter 被【同步】调用，work 是【异步】排的，getter 捕获永远先命中 |
| **setter hook 强制值作解耦写入**（v10.4/v10.5 `adsp_force`）| ❌ 两种模式实测均无效：驱动只在「vote 目标≠当前ADSP」时才调 setter 写，日常值相同不写 → hook 不触发 |

> ⚠️ **调试教训**：用 rmmod + insmod 模拟越狱模式会**假性崩溃**（热卸载 kprobe 不安全），
> 必须用「禁用模块（/data/adb/modules/uv2800/disable）→ 重启 → 手动 insmod」复现真实越狱路径。

## 4. 使用与运维 SOP

### 4.1 首次安装

```sh
1) KernelSU 刷入模块 → 重启                     ← 唯一需要的一次重启
2) 模块开机后经 adsp_write 自动写入解耦目标（2600）
3) 触发一次满电状态切换（三选一）：
     · 充满一次；· SOC=100 时拔充电器；· SOC=100 时插充电器
4) fcc 原生重算 ✅ 完全生效
```

**越狱（late-load）模式**：第 2 步的解耦写入需要**插拔一次充电器**触发 vote
（customize.sh 安装时已提示，无时间限制）；第 3 步照常。

### 4.2 验证是否生效

```sh
cat /sys/class/oplus_chg/battery/vbat_uv                 # 2800
P=/sys/module/uv2800/parameters
echo 1 > $P/adsp_read; cat $P/adsp_read                  # 2600（需 uv_dev 已捕获）
grep -c capacity /proc/mounts                            # ≥1（bind 生效）
dmesg | grep uv2800:                                     # v10 ready, 5 个 hook
dmesg | grep bs_update_data | tail -1                    # fcc ≈5000 ★唯一可靠指标
```

> ⚠️ **不要用 `/sys/class/oplus_chg/battery/battery_fcc` 验证解容效果**。
> 该节点每次读都实时调用 gauge IC 查询（`battery_fcc_show` →
> `oplus_gauge_get_batt_capacity_mah`，无缓存），但查询失败时（`oplus_get_gauge_type`
> 返回 `-ENOTSUPP`，实测每 5 秒报错）会**回退到 `design_capacity`**（本机 5920），
> 显示的不是电量计真实 fcc。**请用驱动 `bs_update_data` 日志里的 `fcc`**。
>
> 越狱模式下若 `adsp_read` 返回 `0`（dmesg 显示 dev=0000000000000000），
> 说明 vote 还没触发 —— **插拔一次充电器**即可（无时间限制）。
> 判据「已解耦」：`adsp_read`（2600）≠ `vbat_uv`（2800）。
>
> ★ **一次插拔双用**：`uv_dev` 在同一次 insmod 生命周期内持续有效，
> 故同一次开机内「安装解耦」与「卸载回写」共用这一次捕获，**无需重复插拔**；
> **但重启（rmmod+insmod）后会归零，需重新插拔一次**。

### 4.3 卸载（顺序不能错）

```sh
1) 【必须】电量充足（>50%，电压 >3250mV）时点 KernelSU 模块的「执行」按钮
      → 自动算原值回写 + 恢复超级省电 + 恢复官方平滑显示
      ⚠️ 低电压回写会让电量计进入钳位态（SOC 卡 0%，需充满一次才恢复）
      ⚠️ 越狱模式：若未就绪会提示插拔充电器，请插拔后重点「执行」
2) 删除/禁用模块，重启
3) 验证：cat /sys/class/oplus_chg/battery/vbat_uv   → 应显示原值（如 3250）
```

**如果只删模块不点按钮**：关机电压恢复 3250，但 ADSP 里仍是 2600/2800 →
电量计空电点低于关机点，**还有百分之几就关机**。恢复方法：重装模块 → 点按钮。

### 4.4 重新启用模块

```sh
rm /data/adb/uv2800_backup/skip     # 否则「禁止超级省电」不会重新应用
```

### 4.5 自定义

```sh
# 改解耦目标（电量计模型下限，默认 2600）
echo 2800 > /data/adb/uv2800_backup/adsp_target   # 2800=不解耦 / 3000=保守
# 下次开机 service.sh 会经 adsp_write 写入（或点「执行」后立即生效）
```

---

## 5. 跨版本兼容性

### 5.1 验证矩阵

| 层 | COS17 | COS16 | COS15 | 方法 |
|---|---|---|---|---|
| 内核符号 CRC | ✅ | ✅ | ✅ | 三版本 Module.symvers 实测一致 |
| 显示链挂钩点 | ✅ | ✅ | ✅ | 归一化反汇编逐指令比对 |
| getter/setter 挂钩点 | ✅ | ✅ | ✅ | profile 表 + 指令字签名 |
| setter ABI | (dev,int) | (dev,int) | (dev,int*) | profile set_ptr |
| adsp_write 主动写（解耦依据）| ✅ | ✅ | ✅ | 命令 0x800A，三版本反汇编确认 |
| 硬件命令 0x800A | ✅ | ✅ | ✅ | 反汇编确认 |
| 设备策略键 | ✅ 真机 | ✅ jar | ✅ jar | oplus-services.jar grep |
| action.sh 回写取值 | ✅ 真机 | ✅ adsp_orig 优先 | ✅ adsp_orig 优先 | 两级取值 |
| 电量计 term→fcc 行为 | ✅ 真机 | ⚠️ 未验证 | ⚠️ 未验证 | 固件无法静态分析；最坏退化为旧行为，不损坏 |

### 5.2 失败安全

| 场景 | 行为 |
|---|---|
| 驱动更新导致指令字不匹配 | init 拒绝加载，手机正常开机（无 hook）|
| profile 不匹配 | 只注册 2 个显示 hook，ADSP 功能禁用 |
| KMI 变化（CRC 不匹配）| insmod 被内核明确拒绝 |
| 越狱模式未插拔充电器 | 关机保护正常，解耦/回写暂不就绪，action.sh 超时硬中止 |
| late-load 下 nsenter 不可用 | 回退当前命名空间 bind |

---

## 6. 风险与限制

| 风险 | 说明 | 缓解 |
|---|---|---|
| 电池寿命 | 2800mV 是硅碳负极放电下限，长期深度放电加速老化 | 可只改 ADSP 解容、不常用到低电压段 |
| 低电压回写 | vbat < 回写目标时电量计钳位（DOD=100% 不自愈）| action.sh 已加 <3300mV 醒目警告 |
| adsp_orig.txt 丢失 | 兜底查 DT 表，C15/16 末档封顶可能偏差（≤100mV）| 偏差无安全影响；重学习一次即收敛 |
| oplusdevicepolicy 大 Transaction | /data/system 策略 XML 堆积导致（社区已知）| service.sh 检测并提示反馈 |
| 电量计固件行为（COS15/16）| term→fcc 重算未经真机验证 | 首次放电观察 0% 落点即可确认 |
| 真实越狱模式 | nsenter 分支只经模拟验证 | 最坏回退当前命名空间 bind |
| 越狱模式解耦/回写未就绪 |  vote 是事件驱动，充电状态稳定时不触发 | **插拔一次充电器**（无时间限制）；customize.sh/action.sh 均有提示 |

---

## 7. 文件索引

### 开发机（项目工作区）

| 路径 | 说明 |
|---|---|
| [PROJECT-vbat_uv-2800.md](PROJECT-vbat_uv-2800.md) | 本文档（当前技术栈 v10.6）|
| [PROJECT-history.md](PROJECT-history.md) | v1~v10.3 演进史、判死路线、实测证据 |
| [_work/ksu-module/uv2800/](_work/ksu-module/uv2800/) | **当前模块打包源（v10.6）** |
| [_work/ksu-module/一加13解容-v10.6.zip](_work/ksu-module/一加13解容-v10.6.zip) | **当前发布包** |
| [_work/uv2800/uv2800_v10.c](_work/uv2800/uv2800_v10.c) | **当前内核源码（v10，5 个 kprobe）** |
| [_work/uv2800/uv2800_v10.ko](_work/uv2800/uv2800_v10.ko) | 当前 ko（30728 字节）|
| [_work/uv2800/uv2800_v10.c](_work/uv2800/uv2800_v10.c) | v10 内核源码（保留）|
| [_work/uv2800/tools/](_work/uv2800/tools/) | 构建/提取/分析脚本（见 README）|
| [_work/uv2800/tests/](_work/uv2800/tests/) | 设备端测试脚本（见 README）|
| [_work/uv2800/docs/](_work/uv2800/docs/) | 放电曲线图、日志留档 |
| [_work/uv2800/archive_deprecated/](_work/uv2800/archive_deprecated/) | v1~v8 全部源码与 ko |
| [_work/versions/](_work/versions/) | COS15/16/17 三版本 oplus_chg_v2.ko 与 framework jar |
| [_work/v10/](_work/v10/) | v10 及更早的快照与归档 |

### 设备上

| 路径 | 说明 |
|---|---|
| /data/adb/modules/uv2800/ | 当前安装模块 |
| /data/adb/uv2800_backup/ | 备份与开关（见 §2.3）|
| /sys/module/uv2800/parameters/ | adsp_read / adsp_write / restore |

### 构建环境（易失，/tmp）

| 路径 | 说明 |
|---|---|
| /tmp/op13b | 一加 13 内核源码树（oneplus/sm8750_b_16.0.0_oneplus_13）|
| /tmp/uvmod | 模块构建目录（Makefile: obj-m := uv2800.o）|
| /tmp/tc/bin | 工具链（clang-18 + ROCm llvm 工具）|

重建构建环境：见 [_work/uv2800/tools/README.md](_work/uv2800/tools/README.md)。

---

## 8. 踩坑速查（精简版，完整血泪史见 history）

| # | 坑 | 一句话教训 |
|---|---|---|
| 1 | kCFI 缺失 → 手机重启两次 | 函数指针调内核函数必须 no_sanitize("kcfi") |
| 2 | sysfs 显示值 ≠ 真实值 | vbat_uv 有显示缓存层；验证看驱动内部口径 |
| 3 | 写入 term > 电池电压 → 钳位不自愈 | 回写前必须先充到 3250mV 以上 |
| 4 | 「备份型配置」无脚本生成则静默失效 | 可选文件控制行为必须自动生成 + 日志可见（adsp_target 即此教训）|
| 5 | vote 是事件驱动非定时 | 解耦/回写触发只能靠插拔充电器，后台死等无意义（v10.3 的 1 小时重试已删）|
| 6 | 模拟越狱用 rmmod+insmod 会假崩溃 | 必须「禁用模块 → 重启 → 手动 insmod」 |
| 7 | vote 触发时 getter 同步被调、work 异步排 | work 反推 chip 是冗余设计（v10.4 曾实现已移除）|
| 8 | adb shell 多层引号下管道静默产空 | 验证类命令一律落盘成脚本再执行 |

> 完整的版本演进（v1~v10.3）、判死路线（显示层 SOC 修正、restore=1 等）、
> 每一步的实测证据，全部归档于 [PROJECT-history.md](PROJECT-history.md)。