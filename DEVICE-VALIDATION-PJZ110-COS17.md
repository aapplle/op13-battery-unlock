# PJZ110 / ColorOS 17 真机验证

验证日期：2026-10-03。使用仓库现有 v10.8 发布包，无需修改内核 profile 或重新编译。

## 设备

| 项目 | 实测 |
|---|---|
| 机型 / device | PJZ110 / OP5D0DL1 |
| 系统 | PJZ110_17.0.0.101(SP02CN01)，Android 17 |
| 安全补丁 | 2026-09-01 |
| 内核 | 6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k |
| Root 管理器 | ReSukiSU，ADB `su -c id` 返回 uid=0 |
| 电池 DT 节点 | silicon_p_770 |
| deep_dischg_counts | 824 |
| 操作前电量 / 单芯电压 | 100% / 4434mV |

## 兼容性检查

从真机提取 `oplus_chg_v2.ko`，SHA256：

```
205fb7ebdd5d12438fbd40e7432d12c034929c629a8657ca17f38d50de7c63ce
```

以下指令字均与 `uv2800_v10.c` 一致：

| 符号 | 偏移 | 指令字 |
|---|---|---|
| oplus_comm_update_vbat_uv_thr | 0x2c | 0xb9400108 |
| oplus_comm_update_vbat_uv_thr | 0x30 | 0xb9000268 |
| vbat_uv_show | 0x10 | 0xaa0203e0 |
| vbat_uv_show | 0x20 | 0x2a0803e2 |
| oplus_fg_get_deep_term_volt | 0xe0 | 0xb9000263 |
| oplus_fg_set_deep_term_volt | 0x34 | 0x2a0103f3 |

驱动与模块共有的 `__stack_chk_fail`、`_printk`、`kstrtoint`、`module_layout` CRC 全部一致。
随后实机 `insmod` 返回 0，内核日志确认 `5 个 hook, profile=[ColorOS 16/17]`，完成实际加载验证。

v10.8 ZIP CRC 检查通过；包内脚本文本与工作区一致（工作区 CRLF、包内 LF），内核模块二进制一致。
模块 SHA256：

```
471df911d0d812f7b58b8466c55ae08d8dc57aa7cf2b682931e39cec572101e1
```

## 安装及当前开机验证

通过 `ksud module install` 安装 v10.8。为在当前开机内验证，从安装暂存目录加载内核模块，
将同一套安装文件复制到 `/data/adb/modules/uv2800/`，以 `KSU_LATE_LOAD=1` 启动服务。
用户完成 USB 拔插后验证：

| 项目 | 结果 |
|---|---|
| `vbat_uv` 读数 | 2800mV |
| 触发 `adsp_read` 后的真实电量计值 | 2600mV |
| `adsp_write` 内核返回值 | 0 |
| 首次写入前的真实值备份 | `/data/adb/uv2800_backup/adsp_orig.txt` = 3000 |
| 恢复脚本试运行 | DT 计算和备份读取均得到 3000mV，未执行恢复写入 |
| 显示绑定 | PID 1 mountinfo 确认 chip_soc → battery/capacity |
| 超级省电策略 | Binder 读取 `oplus_diable_super_power_saving_mode` 返回 true |
| 驱动 `bs_update_data` FCC | 操作前 4976，操作后 5160mAh |

**本次写入前的备份值和恢复脚本目标均为 3000mV，不能套用文档示例的 3250mV。**
`term_coeff` 第一行是 `(3000, 1300, 12)`；恢复脚本将第二字段当作计数门槛，与 824 比较后使用第一档兜底。
这仅复现恢复脚本的计算，不代表原厂驱动的实际选值逻辑（见下方后续核查）。
历史日志显示此前模块已执行过一次恢复并写入 3000mV，因此本次直读不是未经修改的原厂基线证据。
应将“本次安装前的真实参数”与“原厂驱动在当前电池状态下应选的参数”分开理解。

## 后续核查：原厂 DDRC 目标实际为 3100mV

用户指出最初读数为 3100mV 后，交叉检查原厂驱动反汇编、实时 DT 和本次加载 hook 前的内核日志，确认当前策略目标为 **3100mV**。
这不是 `oplus_chg_v2.ko` 内所有设备通用的固定常数，而是当前 DDRC 曲线的选值。

实际选中的曲线为：

```
silicon_p_770/ddrc_strategy/strategy_ratio_range_low/strategy_temp_normal
```

按大端 u32 解码，每行四字段：

| 策略计数门槛 | shutdown 目标 mV | term 目标 mV | 索引 |
|---|---|---|---|
| 0 | 3000 | 3060 | 0 |
| 15 | 3000 | 3060 | 1 |
| 400 | 3050 | 3100 | 2 |
| 800 | 3150 | 3200 | 3 |
| 1200 | 3150 | 3200 | 4 |

本次加载 hook 前的日志（内核时间 646 秒；hook 在 943 秒加载）：

```
ddrc_strategy_init: use strategy_ratio_range_low:strategy_temp_normal curve
oplus_fg_get_deep_term_volt: deep_term_volt=3000
oplus_gauge_get_ddrc_status: [0, 0][3100, 3000, 3050, 2950] [412, 412, 824, 20, 0]
```

反汇编证据：

- `oplus_gauge_get_ddrc_status+0x144` 从驱动对象 `+0x100c` 读取策略计数，当前日志为 412，而不是直接使用 sysfs 的 824。
- `+0x1a0..+0x1d8` 从 16 字节曲线行读取 shutdown/term 值并提交目标投票。
- `+0x3bc..+0x3dc` 取两路目标投票结果，`+0x814..+0x81c` 将 term 目标、硬件现值、shutdown 目标依次放入日志参数。因此日志中的 3100 是策略目标，3000 是此前已保存的硬件值。
- `oplus_gauge_parse_deep_spec+0xac..+0xb8` 将 `term_coeff` 读入对象 `+0x1858`；`oplus_gauge_term_voltage_vote_callback+0xec..+0x138` 按输入**电压**查该表，读取后两个字段。恢复脚本直接按总计数反查该表，未复现 DDRC 路径。

结论：当前 `adsp_orig.txt=3000` 只适合作为本次操作前状态的记录；不能据此认定正确原厂恢复目标为 3000。
现有 v10.8 恢复脚本仍会选择 3000，其原厂恢复逻辑存在缺陷。本次核查未修改手机参数或备份，未执行恢复；当前解容仍为 ADSP 2600 / hook 2800。

## 验证边界与后续使用

- 本次未重启；KernelSU 的 `modules_update/uv2800` 及 `update` 标记保留，供下次正常启动完成安装收尾。本次开机已实际加载并运行。
- 重启后的自动加载尚未验证；若使用临时 Root，需按该 Root 方案重新激活，并按模块提示插拔充电器。
- FCC 是电量计估计值。设备历史日志显示此前用过解容模块，4976 不是已确认的全新原厂基线；本次不据此计算续航提升比例。
- 未执行完整放电、实际低电压关机或容量测量，2800mV 为 hook 和节点验证结果。
- 卸载前在电量充足时使用模块「执行」恢复原值，按提示插拔，再卸载。


## v10.9 修复

发现原厂提供 `/proc/oplus-votable/TARGET_TERM_VOLTAGE/status`：

```
TARGET_TERM_VOLTAGE: DEEP_COUNT_VOTER: en=1 v=3100
TARGET_TERM_VOLTAGE: effective=DEEP_COUNT_VOTER type=Max v=3100
```

对应 `force_active=0`。该接口直接提供策略目标，无需重建 DDRC 选曲线、计数换算与多路投票逻辑。
与之对比，`GAUGE_TERM_VOLTAGE` 的当前值为被 hook 影响的 2800，不适合作为恢复来源。

v10.9 已删除旧备份优先和 `term_coeff` 兜底。恢复时读取并校验实时有效目标；异常即停止。
历史备份 3000 保留。手机只读试运行返回 3100，未回写电量计；19 项 Android sh 回归用例通过。
另有 6 项 action.sh 隔离测试通过，覆盖只读试算、强制投票、接口缺失、skip 创建失败、写入失败及回读不符。
隔离测试将脚本中的设备路径映射到临时普通文件，没有访问真实回写节点。

已通过 KernelSU 安装 v10.9，并同步当前开机使用的脚本；内核模块二进制保持不变，没有热卸载或重新加载。
当前目录和待重启安装目录中的 9 个运行文件均逐字节匹配发布包；安装器正常清理了仅安装时使用的 `customize.sh`。
部署前的活动脚本保存在 `/data/adb/uv2800_backup/scripts-before-v10.9/`（版本元数据在安装时已更新，备份用于保留旧脚本）。

部署后只读试运行目标为 3100mV。前后快照核对：ADSP=2600、vbat_uv=2800、历史备份、备份日志、设备策略及全局显示挂载均未变化。
ZIP CRC、LF 换行、内容一致性和 shell 语法检查通过。
发布包 `_work/ksu-module/一加13解容-v10.9.zip` SHA256：

```
bb19265101c422516b713b4c9a98fbdc2c29be6fe7515f5224eda25df9764e81
```

本次未执行真实恢复回写或重启；COS15/16 的新恢复接口仍待真机验证。

## 用户要求恢复后的实际验证

随后按用户要求执行 v10.9 `action.sh`，当时电量 100%、单芯电压约 4436mV。
实时策略目标 3100mV，内核写入返回 0，`adsp_read` 回读 3100mV；日志确认所有 hook 已放行。
用户完成 USB 插拔后，验证如下：

| 项目 | 恢复后 |
|---|---|
| 电量计 deep_term_volt | 3100mV |
| vbat_uv | 3100mV |
| GAUGE_TERM_VOLTAGE 有效投票 | 3100mV |
| TARGET_SHUTDOWN_VOLTAGE | 3050mV（DDRC 目标） |
| GAUGE_SHUTDOWN_VOLTAGE 有效投票 | 3100mV（SUPER_ENDURANCE_MODE_VOTER，取 Max） |
| chip_soc 全局绑定 | 已解绑 |
| 禁超级省电策略 | Binder 回读 false |
| 当前模块 / 待安装副本 | 两处均已加 disable，保留 skip 停止自动解耦 |

本次没有热卸载内核模块或重启；内存中的 hook 已放行，不再强制原来的值。
FCC 仍约 5150mAh，学习值没有随参数恢复立即复原。未进行完整放电能量测量，因此本次数据仅证明参数修改与恢复，
以及电量计估计值变化，不证明真实放电容量提升比例，也不证明存在被锁住的标称容量。
