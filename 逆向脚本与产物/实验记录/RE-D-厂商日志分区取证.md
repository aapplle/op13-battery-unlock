# RE-D — OnePlus 13 (PJZ110) 厂商持久化日志分区取证

> ⚠️ **[2026-10-05 更正（RE-F，134 条样本）] 本文有两处结论已被更正，阅读时请一并参考 `RE-F-重算方案与厂商日志比对.md`：**
> ① 文中「`count_cali` = 172/222/310」是**误读** —— 那是 `ddrc_status` 五元组首元素 `oplus_fg_get_last_cc`；
>    **`count_cali` 全语料恒为 0**。
> ② 第四批 #4 的「`vterm_final` = 2800」把 β 记录的 `vterm`（= `term_now`，IC 实持）当成了 `vterm_final`；
>    该 boot 的**真实表输出是 3060**（α 记录 @0x1553320）⇒ 「2800→3060 由 index_t 2→3 解释」**不成立**，
>    2800 是**外部写入 IC 的值**（社区 dtbo 解容期）。
> 本文其余取证（分区清单、`vterm_final` 恒 3250、开机驱动改写、AVB 证据）仍然有效。

- 设备：`adb -s <SERIAL>`（PJZ110，Android 16，当前 build `PJZ110_16.0.5.701(CN01)`，内核 `6.6.89-android15-8-g7e1f3c083cc6`，KernelSU root）
- 日期：2026-10-05（设备 RTC）
- 原则：**全程只读**。未做任何 mount rw / 擦除 / 格式化。oplusreserve2 本来就是系统 rw 挂载，只读访问。
- 宿主产物：`/tmp/oxlogs/`
  - `ox1.tar` / `ox2.tar`（设备端 tar，含 oplusreserve 主要子目录 + /data/persist_log 部分）
  - `x1/` `x2/`（解包结果）
  - `raw/raw/{sdf2,sdf4,sdf5,sdf6,sde73,sde74,sde75,sde84}.bin`（整盘 dd）
  - `md/m{1,2,3}/`（3 个 minidump gz 解出的 tar：device.info / minidump.bin）
  - 脚本：`scan1.py scan2.py scan3.py raw1..raw5.py scan9.py stamp.py`

---

## 1. 分区清单（全部实测）

| 分区 | 节点 | 实测大小 | 文件系统 / 格式 | 非零字节 | 判定与内容 |
|---|---|---|---|---|---|
| **oplusreserve1** | /dev/block/sdf2 | 8 MiB | **无 FS（裸区）** | 746,268 (8.90%) | 头 64 B = UFS 器件描述符（magic `5a 3a b7 9f fa e6 6c 7b` + `SKhynix` + `HN8T274EJ KX130` + `104A`，与 device.info 的 `HN8T274EJKX130` 一致）。其余 = **XBL/PHOENIX2.0 引导日志环形区**（PBL/CPBL/APBL 时间戳、`ChargerLibTarget_GetBatteryStatus`、`i2c term voltage`）。**有料** |
| **oplusreserve2** | /dev/block/sdf3 | 256 MiB | **ext4**（LABEL=`opporeserve2`，UUID `62e0cd6f-2d85-408e-9f6d-dc09a11f029e`） | — | 已 rw 挂载：`/mnt/vendor/oplusreserve`、`/mnt/oplus/op2`，并被 bind 到 `/data/persist_log/{oplusreserve,cache/factory,criticallog,storage/op2storagelog,oplus_fsck_fulldiskscanuserdata}`。用 215 MB。**主料区** |
| **oplusreserve3** | /dev/block/sdf4 | 64 MiB | **无 FS（裸区）** | 5,242,880 (7.81%) | **内核日志环**。有效数据只落在 `0x0100_0000–0x014F_0000`（约 5 MiB）。含 `OPLUS_CHG` + `KernelSU`(5524 次) + `uv2800` 模块日志。**有料** |
| **oplusreserve4** | /dev/block/sdf5 | 32 MiB | 无 FS（裸区） | **0（0.00%）** | **完全空白，从未写过**。头 64 B 及整盘全 0，无 ext4 magic、无任何字符串 |
| **oplusreserve5** | /dev/block/sdf6 | 64 MiB | 无 FS；首 8 B `a9 07 00 00 00 00 00 00` + `PHOENIX2.0` | 19,029,483 (28.36%) | **内核日志环，跨 8 次开机**（`Booting Linux on physical CPU` 出现在 0x40101a/0x60101a/…/0x120101a，每隔 2 MiB 一个 session）。含完整 `deep_term_volt` 与 `uv2800` 模块日志。**最有料** |
| **logfs** | /dev/block/sde74 | 8 MiB | **FAT12**（blkid: `TYPE="vfat" SEC_TYPE="msdos" LABEL="LOGFS" UUID="D273-55EA"`） | 497 (0.01%) | 只读挂载成功但**根目录为空**。全部非零数据 = 引导扇区(0x0) + 两份 FAT12 表(0x1000/0x2000，内容 `f8 ff ff`) + 0x3000 处 1 条空卷标 8.3 条目 `LOGFS`。**无数据** |
| xbl_sc_logs | /dev/block/sde84 | **128 KiB**（不是 8 MB） | 裸区，magic `IMTL` | 122,785 (93.68%) | 7 份 PBL/CPBL/APBL 引导日志副本；**无任何电池/电量计行**（`i2c term voltage` 出现 0 次） |
| rawdump | /dev/block/sda11 | 256 MiB | 裸区 | 抽样 8 点（0/32/64/96/128/160/192/224 MiB）**全 0** | 崩溃转储暂存区，当前已清空。无料 |
| （附带）| sde73 | 1 MiB | UEFI FV（`_FVH` @0x28） | 391,638 (37.35%) | 固件卷，非日志 |
| （附带）| sde75 | 128 KiB | ELF64 aarch64 ET_DYN | 11,643 (8.88%) | 固件镜像 |

### 关键澄清（避免误判）
`EFI_GetBootToHlosThd param 3350 -100 50 50 50 50 3000 3400 3150 0 0 3400 3050`
中的 **3350 是引导器固定入参，每次开机都一样，出厂日志里也是 3350**（厂测 `sbl_memtest.log` 同时出现 `param 3350` 和 `i2c term voltage 3060`）。**它与电量计终止电压无关，不能当作"原厂 3350"的证据。**
真正从电量计 IC 读到的是同一段日志里的 `i2c term voltage <N>`（`gauge_ic:0, term_volt_reg:0x4A, term_ratio:2`，即 bq28z610 的 0x4A 寄存器）。

---

## 2. 有用数据原始片段

### 2.1 【最强证据】oplusreserve1 (sdf2) — 引导器直接读电量计 0x4A 寄存器

文件：`/dev/block/sdf2` → `/tmp/oxlogs/raw/raw/sdf2.bin`，**按文件偏移 = 时间顺序**：

```
0x043d06b  ChargerLibTarget_GetBatteryStatus,BatteryVoltage = 8736,BatteryTemperature = 40,ChargeCurrent = -37
           EFI_GetBootToHlosThd param 3350 -100 50 50 50 50 3000 3400 3150 0 0 3400 3050
           EFI_GagueSupportMutexIc not support.
           gauge_ic:0, term_volt_reg:0x4A, term_ratio:2
           i2c term voltage 3350          <-- 第 1 次
0x0444072  ... 同样结构 ...
           i2c term voltage 3250          <-- 第 2 次
0x044b069  ... 同样结构 ...
           i2c term voltage 2540          <-- 第 3 次
0x0452072  ... 同样结构 ...
           i2c term voltage 3250          <-- 第 4 次
```

**这是整个取证里最硬的一条**：3350 这个值**真的存在于电量计 IC 里**（引导器在 Android 起来之前用 I2C 从 0x4A 直接读出），不是第三方 App 的显示问题、也不是模块伪造的读数。
该分区只保留了 4 次这种读取（更早的被环形覆盖）。

### 2.2 【决定性上下文】oplusreserve5 (sdf6) — 跨 8 次开机的完整 `deep_term_volt` 序列

文件：`/tmp/oxlogs/raw/raw/sdf6.bin`，按偏移排序（= 开机顺序）：

```
0x05c764f  deep_term_volt=2540
0x068d4f3  deep_term_volt=3250      (uv2800 模块日志在附近)
0x086aad3  deep_term_volt=2540
0x0928ae6  deep_term_volt=3350   |  ddrc_status [0, 0][3250, 3350, 3200, 3300] [340, 344, 1758, 51, 0]
0x09ea793  deep_term_volt=2540
0x0ab079a  deep_term_volt=3250   |  ddrc_status [0, 0][3250, 3250, 3200, 3200]
0x0b1f5d4  deep_term_volt=2540   |  ddrc_status [0, 0][3250, 2540, 3200, 2490]
0x0d24ead  deep_term_volt=3350   |  ddrc_status [3250, 3350, 3200, 3300]
0x0d91f76  deep_term_volt=2540   |  ddrc_status [3250, 2540, 3200, 2490]
0x0f3500f  deep_term_volt=2540
0x0fb3ba9  deep_term_volt=3350   |  ddrc_status [3250, 3350, 3200, 3300]
0x113a612  deep_term_volt=3350
0x11aec6d  deep_term_volt=2540   (ColorOS 15 profile 的 uv2800 之后)
0x1384e1d  uv2800: ---------- uninstall.sh 卸载 开始 ----------
0x1384e71  uv2800: 模块已禁用（未 rmmod，hook 保持生效）
0x1389195  uv2800: 卸载完成（日志保留在 /data/adb/uv2800_backup/uv2800.log）
0x13a6839  deep_term_volt=3350   <-- 卸载模块之后，电量计回到 3350
0x13a8065  deep_term_volt=3350
0x13aa958  deep_term_volt=3350   |  ddrc_status [3250, 3350, 3200, 3300]
0x13c514a  deep_term_volt=3350
0x13c9191  deep_term_volt=3350   |  ddrc_status [3250, 3350, 3200, 3300]
0x14edf7b  ddrc_status [3250, 2600, 3200, 2550]
0x153b480  deep_term_volt=3250   |  ddrc_status [3250, 3250, 3200, 3200]
0x15d60c5  deep_term_volt=3250   |  ddrc_status [3250, 3250, 3200, 3200]
```

**四元组语义已可确定**：`[vterm_final, term_now, vterm_final-50, term_now-50]`
- `vterm_final`（DDRC 计算出的目标值）：**除早期 3060 外，全部记录恒为 3250**
- `term_now`（电量计实际持有的值）：3250 / 3350 / 2540 / 2600 / 2800 都出现过
→ 用户观察到的"低 50 mV"其实是这四元组里固定的第二对（`-50`），不是 SOC 依赖行为。

### 2.3 【模块自证】uv2800 模块的完整行为日志

`sdf4.bin`（oplusreserve3）`0x14e8b29` 起：

```
uv2800: ---------- service.sh 开始（KSU_LATE_LOAD=1） ----------
uv2800: v11.0 init (vbat_uv=2800 mV, adsp=2540 mV)
uv2800: 校验通过 oplus_comm_update_vbat_uv_thr+0x2c (ldr w8,[x8])
uv2800: 校验通过 oplus_comm_update_vbat_uv_thr+0x30 (str w8,[x19])
uv2800: 匹配 profile [ColorOS 16/17]  getter+0xe0 setter+0x34 ABI=(dev,int)
uv2800: v11 ready, 6 个 hook, profile=[ColorOS 16/17], vbat_uv=2800 adsp=2540
uv2800: 回写入口 /sys/module/uv2800/parameters/adsp_write（写电压值，如 3250）
uv2800: uv_dev 未捕获，主动触发 deep_dischg 入口（v10.19）
uv2800: 从 deep_dischg 入口捕获 device=ffffff889b5cf000
uv2800: 触发后 adsp_read=2540
uv2800: 关机电压 V_s=2800 mV，ADSP 派生=2540 mV（偏移 260，FLOOR=3060）
uv2800: ADSP 探测：0s 后就绪（终止电压 2540 mV）
uv2800: 电量计终止电压已是 2540 mV，无需写入
uv2800: 已绑定 chip_soc -> capacity（nsenter -t 1 -m，全局命名空间）
uv2800: 设备策略 oplus_diable_super_power_saving_mode=true（waited 0s）
uv2800: ---------- action.sh 恢复原值 开始 ----------
uv2800: [adsp_write] 写 3250 mV，返回 0（强制仍生效）
uv2800: resume=1，已退出恢复模式，所有 hook 重新生效
uv2800: 恢复完成：原值 3250 mV，vbat_uv 刷新=skip（skip=本已相等，0=未生效待重启）
```

`sdf6.bin` 里还有第二、三个 profile：

```
0x11976e0  uv2800: 匹配 profile [ColorOS 15]  getter+0x78 setter+0x58 ABI=(dev,int*)
0x1197746  uv2800: v11 ready, 6 个 hook, profile=[ColorOS 15], vbat_uv=2800 adsp=2540
```

minidump（2026-10-03，F.05 build，模块 v10）里：

```
uv2800: v10 init (target 2800 mV)
uv2800: 回写入口 /sys/module/uv2800/parameters/restore（写电压值，如 3250）
uv2800: 直读 ADSP deep_term_volt = 3250 mV (rc=3250)
uv2800: [adsp_write] 写 2600 mV，返回 0（强制仍生效）
```

**结论性事实**：模块的挂钩点是 `oplus_comm_update_vbat_uv_thr`（ldr/str w8 两处）与 `vbat_uv_show`；它自己把 mock 的"原值/回写值"举例写成 **3250**，并在恢复动作里**写 3250**。**在所有分区日志中，没有任何一条 `adsp_write 写 3350` 或 `写 3400` 的记录。**

### 2.4 【3250 与 1758 同框】持久化 DCS kevent

`/data/persist_log/DCS/kevent/kevent_record_dcs_OplusCharger_1005015602_394_complete.txt:1`（1170 B，2 行）

```
OplusCharger,charge_monitor,payload@@charge_monitor$$track_ver@@4.0$$battery_type@@silicon_p_770$$type_reason@@device_abnormal$$flag_reason@@Batt_Id_Info$$time@@[1970-07-22 12:14:41]$$device_id@@oplus,virtual_gauge$$err_type@@0$$ic_msg@@$$deep_support@@1$$byb_id@@3$$batt_id@@3$$sili_err@@0$$counts@@1758$$uv_thr@@3250$$OtaVersion@@PJZ110_11.C.86_1860_202603040058$$Time@@17468081
```
第 2 行（bq28z610 寄存器转储）：
```
...$$time@@[2026-01-01 00:00:32]$$device_id@@bq28z610$$...$$reg_info@@time[2026-01-01 00:00:32]-0x06=54,0c|0x08=32,21|0x0a=c0,00|0x0c=05,fa|0x10=5a,07|0x12=f4,07|0x14=39,fb|0x2a=58,01|0x2c=5d,00|0x2e=61,00|0x0006=15,77|0x0056=40,1a,09|0x0071=9b,10,97,10,00,00,00,00,31,21,26,21|0x0073=d2,07,04,06,33,00,2c,00,81,08,9b,06,4d,0c,4c,0c|0x0074=02,0e,02,02,33,00,1a,00,00,00,80,04,80,04,7c,00,6b,00,11,00,50,03,50,03|0x0075=bb,0a,b4,0a,90,04,90,04,6f,00,3a,00,64,00,34,01|0x0076=00,00,00,00,80,04,80,04$$OtaVersion@@PJZ110_11.C.86_1860_202603040058$$Time@@1767196832
```

⚠ **同一个 DCS 记录在内核日志里有 `uv_thr` 的另一个版本**（见 2.5），persist 里存的是 3250，当场打印的是 3350。

### 2.5 【3250 / 3350 交替的原厂内核日志】

`/mnt/vendor/oplusreserve/tmp_log/recovery_dmesg_log_1`（内核 **6.6.30**，2024-12-17 构建）
```
[   21.080371] OPLUS_CHG[ADSP]([oplus_fg_get_deep_term_volt][8947]): oplus_fg_get_deep_term_volt, deep_term_volt=3350
[   21.085831] OPLUS_CHG[OPLUS_SILI]([oplus_gauge_get_ddrc_status][506]):  [0, 0][3250, 3350, 3200, 3300] [340, 344, 1758, 51, 0]
[   21.138449] OPLUS_CHG[OPLUS_SILI]([oplus_gauge_term_voltage_vote_callback][2305]): term voltage vote client DEEP_COUNT_VOTER, volt = 3350
[   21.138469] OPLUS_CHG[CHG_COMM]([oplus_comm_set_vbat_uv_thr][825]): set uv_thr=3350
[   29.153176] OPLUS_CHG[TRACK]([oplus_chg_track_upload_ic_err_info][7083]): $$device_id@@oplus,virtual_gauge$$err_type@@0$$ic_msg@@$$deep_support@@1$$byb_id@@3$$batt_id@@3$$sili_err@@0$$counts@@1758$$uv_thr@@3350
[   29.153263] OPLUS_CHG[TRACK]([oplus_chg_track_upload_trigger_data][4804]): type_reason:6, flag_reason:55, ...
```

`/mnt/vendor/oplusreserve/recovery/last_kmsg.3`（内核 **6.6.118**，2026-04-08 构建）
```
[   16.312168] OPLUS_CHG[ADSP]([oplus_fg_get_batt_deep_dischg_count][12053]): fg_get_batt_deep_dischg_count, deep_dischg_count=1758
[   16.347569] OPLUS_CHG[ADSP]([oplus_fg_get_deep_term_volt][12138]): oplus_fg_get_deep_term_volt, deep_term_volt=3250
[   16.347572] OPLUS_CHG[OPLUS_SILI]([oplus_gauge_get_ddrc_status][1536]):  [0, 0][3250, 3250, 3200, 3200] [0, 344, 1758, 51, 0]
[   16.353092] OPLUS_CHG[CHG_COMM]([oplus_comm_set_vbat_uv_thr][1054]): set uv_thr=3250
```

`/mnt/vendor/oplusreserve/recovery/last_kmsg`（内核 **6.6.89**，2025-12-08 构建）—— **同一次开机内先读 3350 再写 3250**
```
[    5.313256] oplus_target_term_voltage_vote_callback: target term voltage vote client DEEP_COUNT_VOTER, volt = 3250
[    5.333063] oplus_fg_get_deep_term_volt, deep_term_volt=3350      <-- 读回 3350
[    5.752394] oplus_gauge_get_ddrc_status:  [3250, 3200][3250, 3350, 3200, 3300] [340, 344, 1758, 51, 0]
[    6.291666] oplus_fg_set_deep_term_volt rc=0, volt = 3250          <-- 写回 3250
[    6.291673] oplus_mms_gauge_update_vbat_uv: [3250, 300]
```

`/mnt/vendor/oplusreserve/recovery/last_kmsg.2`（内核 **6.6.66**，2025-07-01 构建）—— 实时降到 2540 并上传
```
[   12.620656] oplus_fg_get_deep_term_volt, deep_term_volt=2540
[   12.627293] oplus_gauge_get_ddrc_status:  [0, 0][3250, 2540, 3200, 2490] [340, 344, 1758, 51, 0]
[   12.637986] oplus_comm_set_vbat_uv_thr: set uv_thr=2800
[   12.734480] oplus_chg_track_upload_trigger_data: type_reason:2, flag_reason:19, crux_info[$$track_reason@@vote$$temp_p@@3$$temp_n@@3$$ratio_p@@3$$ratio_n@@3$$vstep@@20$$vterm_final@@3250$$term_now@@2540$$index@@2$$dischg_counts@@1758$$count_thr@@300$$count_cali@@0$$cc@@344$$...
```

### 2.6 【深度放电计数 / 排产&老化】factory 目录

`/mnt/vendor/oplusreserve/factory/`（2025-09-11 ~ 2025-09-18，mtimes 大多为 RTC 未同步的 1970-01-01 04:05/12:05/14:05）：

- `sbl_memtest.log`（131 KB）——**厂测引导日志，含电量计读取**：
```
Charger_IC_Init, tbatt = 265, vbatt = 3904, threshold_in_mv = 6700
EFI_GetBootToHlosThd param 3350 -50 50 50 50 50 3000 3400 3000 0 0 3400 3000
i2c term voltage 3060
threshold_logo_mv 3350 to 3110
threshold_logo_mv 3350 to 3010
threshold_logo_mv 3350 to 3400
ChargeStateCheck, i2c_BatteryVoltage = 3902
```
  → **出厂时电量计终止电压是 3060 mV**（后来合并日志里 2025-10~12 也一直是 3060）。
- `agingtest_kmsg.log`（2.0 MB）/ `agingtest_ui.log`（733 KB）/ `dram_aging_user.log` / `flash_aging.log` / `sbl_aging.log` / 各 `*_result.txt`（均 "SUCCESS"）：老化测试跑的是 **SBL / DDR / Flash**，电池部分只见 65% SOC、51.5 °C、`fc=5920000`、`cc=5`，**没有任何 deep_dischg 相关记录**。
- `factory_test_Preferences.xml`：`sblAgingTestSwitch/ddrAgingTestSwitch/flashAgingTestSwitch=true`。

### 2.7 【刷机 / OTA 历史】

`/mnt/vendor/oplusreserve/update_engine_log/`：
| 文件 | mtime | 内部版本串 | 公共版本串 |
|---|---|---|---|
| merge_kernel_log.8 | 2025-10-26 22:54 | — | — |
| merge_kernel_log.7 | 2025-10-26 23:12 | — | — |
| merge_kernel_log.6 | 2025-11-13 16:53 | — | — |
| merge_kernel_log.5 | 2025-12-13 01:00 | `PJZ110_11.C.83_1830_202512070008` | `PJZ110_16.0.2.403` |
| merge_kernel_log.4 | 2026-09-27 03:47 | — | — |
| merge_kernel_log.3 | 2026-09-27 04:13 | — | — |
| merge_kernel_log.2 | 2026-09-27 05:13 | `PJZ110_11.C.94_1940_202609082008` | `PJZ110_16.0.10.501` |
| merge_kernel_log.1 | 2026-09-27 05:20 | `PJZ110_11.F.04_2040_202609192316` | `PJZ110_17.0.0.100` |
| merge_kernel_log | 2026-09-27 23:17 | `PJZ110_11.F.05_2050_202609270850` | `PJZ110_17.0.0.101` |

`update_engine.20260927-045721`：C.93_1930_202608031342 → C.94_1940_202609082008
`update_engine.20260927-051241`：C.94 → F.04_2040_202609192316
`update_engine.20260927-052001` / `231113` / `231610`：F.04 → F.05 / F.05 起
`update_engine.20261005-021039`：无版本串

recovery 记录（`/mnt/vendor/oplusreserve/recovery/last_log*`，按轮转 新→旧 = `last_log`, `.1`, `.2`, `.3`, `.4`）：
| 文件 | recovery build incremental | 对应日期 | security_patch | boot slot |
|---|---|---|---|---|
| last_log | 1772549126267 | **2026-03-03** | 2026-03-01 | `_b` |
| last_log.1 | 1745594264229 | **2025-04-25** | 2025-05-01 | `_b` |
| last_log.2 | 1758210999434 | **2025-09-18** | 2025-09-01 | `_b` |
| last_log.3 | 1785725844921 | **2026-08-02** | 2026-08-01 | `_a` |
| last_log.4 | 1785725844921 | **2026-08-02** | 2026-08-01 | `_a` |

→ 最近 5 次进 recovery 用的 recovery 镜像分别来自 2026-03-03(C.86) / 2025-04-25 / 2025-09-18 / 2026-08-02 ×2。
**2025-04-25 与 2025-09-18 这两个是 ColorOS 15 时代的 recovery —— 与"刷到 C15.0.0.861"一致。**

`recovery/last_ffu_log_all`：`oplus/e: checkFfuFws fws is empty!` / `checkFfuBin fail!!!` → **从未做过 FFU 整包固件升级**。
`recovery/intent` 内容为 `2`；`last_install` 与 `last_ffu` 均为 0 字节。
`rbr_log/last_system_boot_failed.log`（523 B，1970-07-14 13:32）：`init` 与 `Binder:keystore` 的 SIGABRT — 一次开机失败。

### 2.8 【时间戳基准】stamp.db

`/data/persist_log/stamp/stamp.db`（sqlite，92 行，表 `systemstamp(_id,timestamp,dayno,otaversion,hour,eventid,logmap)`）：

```
id=1  ts=17468095561  dayno=19700722 hour=12 ota=PJZ110_11.C.86_1860_202603040058  name=adb_enabled
id=2  ts=17468095562  dayno=19700722 hour=12 ota=(同上)
id=3  ts=1767196833552 dayno=20260101 hour=00 ota=(同上)   -> 2025-12-31 16:00:33 UTC = 2026-01-01 00:00:33 GMT+8
id=4  ts=1791136560228 dayno=20261005 hour=01 ota=(同上)   -> 2026-10-04 17:56:00 UTC = 2026-10-05 01:56 GMT+8
...
id=92 ts=1791140851038 dayno=20261005 hour=03
```

**时间戳换算规则（实测确定）**：
- `timestamp` = 墙上时钟毫秒。当 RTC 未同步时会写成 `17468095561` ms = `17468095.561` s。
- 该值与 kevent 里的 `Time@@17468081`（秒）**一致**，也与 fs_mgr_log 的 `1970-07-22 04:14:xx` 一致 → **"1970-07-22" 不是崩溃时间，而是一个 RTC 复位后的固定时钟值（≈ 202 天 4.25 小时）**。
- `dayno=19700722 hour=12` 是 GMT+8 本地显示，同一时刻 fs_mgr_log 记 `1970-07-22 04:14`（UTC）。
- ⚠ **无法从这些记录反推真实日期**。唯一线索：该机最新内核构建于 `Wed Jul 22 09:32:35 UTC 2026`，与 1970-**07-22** 的月日吻合，**可能**是 RTC 年份字段丢失（2026→1970）导致；但这是推测，未证实。
- ⚠ `otaversion` 字段 92 行**全部**是 `PJZ110_11.C.86_1860_202603040058`，即使时间戳是 2026-10-04、设备当前是 16.0.5.701 —— 这是个**陈旧/固化的属性，不能用来定位版本变化**。

### 2.9 【日志覆盖统计】我到底搜了哪些关键词

设备端 `grep -r -a -l -E` + 宿主端 Python 全量扫（83 个文件 + 8 个整盘 bin + 3 个 minidump tar）：
- 名称类：`deep_dischg` `ddrc` `ddb_curve` `deep_spec` `term_voltage` `term voltage` `TERM_VOLT` `vterm` `ddbc` `deep_term` `uv_thr` `vbat_uv` `gauge_firmware_term_volt` `three_level_term_volt`
- 数值类：`3250` `3350` `3400` `3450` `3150` `3060` `2540` `2800` `2600`
- 器件类：`oplus_chg` `OPLUS_SILI` `sili` `qmax` `bq27` `bq28z610` `nfg` `fuel_gauge` `gauge` `ADSP` `SILI` `DDRC`
- 写操作类：`adsp_write` `set_deep_term_volt` `set_vbat_uv_thr` `oplus_fg_set_deep_term_volt`
- 其它：`KernelSU` `uv2800` `PHOENIX2.0` `IMTL`

**未发现**（明确检索过、确实不存在）：
- 任何 `adsp_write 写 3350` / `写 3400` 记录（只有 `写 3250` 和 `写 2600`）
- 任何 `set_deep_term_volt ... volt = 3350` 记录（只有 `volt = 3250` 和 `volt = 260000` 原始寄存器值）
- LOGFS (sde74) 内任何数据；oplusreserve4 (sdf5) 任何数据；rawdump (sda11) 任何数据
- xbl_sc_logs (sde84) 内任何电池/电量计行

---

## 3. 对四个问题的明确回答

### Q1 有没有电池/电量计/充电相关历史记录？
**有，而且很多。** 分布：
1. `oplusreserve1 (sdf2)`：引导器阶段的 bq28z610 I2C 读取（`i2c_init_bq28z610`、`ChargerLibTarget_GetBatteryStatus`、`i2c term voltage`）
2. `oplusreserve2 (sdf3)` 的 `/data/persist_log/DCS/kevent/`：OplusCharger DCS 记录（含 `counts=1758` / `uv_thr=3250` + bq28z610 寄存器转储）
3. `oplusreserve2` 的 `recovery/last_kmsg{,.1-.4}`、`tmp_log/recovery_dmesg_log_{0,1,2}`、`update_engine_log/merge_kernel_log{,.1-.8}`、`factory/agingtest_kmsg.log`、`media/log/criticalLog/persist/{critical.log,critical.dat}`、`media/engineermode/engineermode_log`
4. `oplusreserve3 (sdf4)` / `oplusreserve5 (sdf6)`：内核日志环，含完整 `oplus_chg` / `OPLUS_SILI` / `ADSP` 输出
5. minidump（`/data/persist_log/oplusreserve/media/log/minidumpbackup/` 与 `.../media/log/minidump/`）

### Q2 有没有出现 3250 / 3350 / 3400 / term_volt / deep_dischg / ddrc / ddbc？
**有。**
- **3250**：`update_engine_log/merge_kernel_log{,.1,.2}`（counts=1699）、`recovery/last_kmsg.3/.4`（counts=1758）、`recovery/last_kmsg`、持久化 kevent（`uv_thr@@3250`）、`sdf6`/sdf4` 大量、模块日志（`原值 3250 mV`、`写 3250 mV`）
- **3350**：`recovery/last_kmsg`、`recovery/last_kmsg.1`、`tmp_log/recovery_dmesg_log_{0,1,2}`、`sdf2.bin@0x043d08d`、`sdf6.bin` 多处、DCS crux `term_now@@3350` / `vbat_uv@@3350`
- **3400**：仅出现在引导器固定入参 `param 3350 ... 3000 3400 ...` 与厂测 `threshold_logo_mv 3350 to 3400` —— **不是电量计终止电压**
- **term_volt / deep_term_volt / deep_dischg / ddrc / ddb_curve / deep_spec**：全部命中（见 2.5 / 2.6 / 2.3）。`ddb_curve` 与 `ddbc` 在厂商日志里**未出现**（这两个名字只存在于内核二进制/DT 中）

### Q3 有没有刷机/OTA/恢复出厂历史？能否定位"3250→3350"变化时间点？
**刷机历史有，但"3250→3350 的确切时间点"无法定位 —— 明确地说：不能。** 原因：
1. `update_engine.*` 日志**只剩 2026-09-27 之后的 6 份**（更早的被轮转掉），而 2026-09-27 那批全是 3250。
2. 能看到 3350 的记录（recovery last_kmsg / recovery_dmesg_log）**RTC 全部未同步**，时间戳退化为 1970-07-22，无法换算真实日期。
3. `stamp.db` 的 `otaversion` 字段被固化成 C.86，无法用来对照时间。
4. **没有 FFU 记录**（`checkFfuFws fws is empty`），所以整包升级不在这些日志里留痕。
5. 所有 `vterm_final`（DDRC 计算目标）除了早期 3060 外**恒为 3250**；变化的是 `term_now`（电量计实持值）。

**能给出的最强时间约束**（按内核版本串 + RTC 可靠性分层）：

| 阶段 | 证据 | deep_term_volt | counts |
|---|---|---|---|
| 出厂 2025-09 | `factory/sbl_memtest.log` | **3060** | — |
| 2025-10-26 | merge_kernel_log.8/.7（内核 6.6.66） | **3060** | 0 |
| 2025-11-13 | merge_kernel_log.6（6.6.89, 2025-09-19 构建） | **3060** | 136 |
| 2025-12-13 | merge_kernel_log.5（同上；C.83 / 16.0.2.403） | **3060** | 256 |
| 2026-09-27 | merge_kernel_log.4/.3（6.6.118, 2026-04-08 构建） | **3250** | 1699 |
| 2026-09-27 | merge_kernel_log.2/.1（6.6.118；C.94→F.04） | **3250** | 1699 |
| 2026-09-27 | merge_kernel_log（6.6.118, 2026-07-22 构建；F.05） | **3250** | 1699 |
| RTC=1970-07-22 | recovery/last_kmsg.3/.4（6.6.118, 2026-04-08） | **3250** | 1758 |
| RTC=1970-07-22 | recovery/last_kmsg.2（**6.6.66**, 2025-07-01） | **2540**（模块） | 1758 |
| RTC=1970-07-22 | recovery/last_kmsg.1（**6.6.30**, 2024-12-17） | **3350** | 1758 |
| RTC=1970-07-22 | recovery/last_kmsg（**6.6.89**, 2025-12-08） | **3350**（读）→ 驱动写 3250 | 1758 |
| RTC=1970-07-22 | tmp_log/recovery_dmesg_log_0/1/2（**6.6.30**） | **3350** | 1758 |
| 无日期 | sdf2 XBL | 3350 → 3250 → 2540 → 3250 | — |

→ **3350 只出现在使用"旧内核"的 recovery 里（6.6.30 / 6.6.89 / 6.6.66 分支），3250 出现在新内核（6.6.118）与所有 OTA 日志里。** 这与"回刷旧版 C15 后看到 3350"高度一致，但**厂商日志本身没有一条记录能给出日期或写入者**，所以只能作为**相关性**，不是因果结论。

### Q4 有没有产线/老化测试痕迹？能否解释 deep_dischg_counts=1758？
**有产线/老化痕迹**：`/mnt/vendor/oplusreserve/factory/`（sbl_memtest / agingtest_kmsg / agingtest_ui / dram_aging_user / flash_aging / 各 result.txt，时间 2025-09-11~09-18）；`media/engineermode/engineermode_log`（2025-09-17 MMI 手动测试，`CAMERA_REAR_WIDE_FLASH_CALIBRATE_TEST: PASS`）；`system/config/secrecy.cfg`（`#Thu Sep 18 03:04:02 GMT+08:00 2025`）。

**但产线老化不能解释 1758 —— 这一点是明确的否定结论**：
`deep_dischg_counts` 有时间序列：**0（2025-10-26）→ 136（2025-11-13）→ 256（2025-12-13）→ 1699（2026-09-27）→ 1758（最后一次）**。
出厂后第一个月是 0，说明**出厂/老化测试期间没有产生任何深度放电计数**；1758 是用户使用期间累积的（且 2025-12-13→2026-09-27 之间从 256 涨到 1699，跨越了用户的刷机/测试期）。
另外 `agingtest_kmsg.log` 里电池只有 65% SOC、51~51.5 °C、充电中的记录，**无深度放电**。

### Q5（附带）有没有内核/驱动日志含 oplus_chg / OPLUS_SILI / DDRC？
**有。** `recovery/last_kmsg{,.1-.4}`、`tmp_log/recovery_dmesg_log_{0,1,2}`、`update_engine_log/merge_kernel_log{,.1-.8}`、`factory/agingtest_kmsg.log`、`oplusreserve3 (sdf4)`、`oplusreserve5 (sdf6)`、3 个 QCOM minidump。
典型行：`ddrc_strategy 0 alloc success` / `parse ddrc_strategy succ num:1` / `use strategy_ratio_range_mid:strategy_temp_warm curve` / `oplus_gauge_parse_deep_spec: chip->deep_spec.limit_curr_curves.nums = 0` / `oplus_gauge_parse_three_level_term_volt_strategy: length=0, term_volt=[0, 0, 0]`。

---

## 4. 其他重要发现

1. **模块自证写 3250，从没写过 3350。** 所有分区里 `adsp_write` 的取值只有 **3250**（恢复动作）和 minidump 里的 **2600**；`oplus_fg_set_deep_term_volt` 的取值只有 **3250**。所以"3350 是模块写进去的"这个假设，**在厂商持久化日志里找不到支持证据**（模块确实能写任意值，但日志没记录它写过 3350）。
2. **模块卸载后，电量计读到的是 3350，不是 3250**（sdf6：`uninstall.sh 卸载开始` → 之后 5 次 `deep_term_volt=3350`）。这是一个值得深挖的反直觉顺序。
3. **原厂驱动每次开机都会把电量计的值改写成 DDRC 目标值 3250**（`oplus_fg_get_deep_term_volt → 3350`，随后 `oplus_fg_set_deep_term_volt volt = 3250`）。也就是说**开机后读到的值可能已被原厂驱动覆盖**，第三方 App 读到的"实时值"取决于读的时机。
4. 四元组 `[vterm_final, term_now, vterm_final-50, term_now-50]` 里的 **−50 mV** 是固定结构，不是 SOC=1% 的行为；"1% 时低 50 mV"可能是这个第二对的误读。
5. `deep_dischg_counts` 与 `uv_thr` 在**同一条 DCS 记录**里同时出现两次、取值不同：persist 里 `counts@@1758$$uv_thr@@3250`，当场内核日志里 `counts@@1758$$uv_thr@@3350`。
6. `oplusreserve2` 的 `media/log/minidump/` 有 3 个共 **176 MB** 的 `SYSTEM_LAST_KMSG@...@PJZ110_11.F.05_2050_202609270850@2026_10_03_*.dat.gz`（= gzip 包着的 tar，内含 `minidump.bin` 87~94 MB + `device.info` + `olc_get_log.txt`），已被拉到 `/tmp/oxlogs/md/`。内含模块 v10 的日志。
7. `oplusreserve2/media/log/vold/` 有 3 个 `storage_*.tar.gz`（2025-11-05、2025-12-03 ×2，共 7.5 MB）—— 存储卡顿现场快照，未展开分析。
8. 设备标识：serialID `0xf8d12d30`；UFS `HN8T274EJKX130` / SKhynix / `A401`；DDR5 Hynix 12G。
9. `oplusreserve1 (sdf2)` 头 64 B 是 UFS 器件描述符（不是文件系统），**不要对它执行 mount**。

---

## 5. 置信度

| 结论 | 置信度 | 依据 |
|---|---|---|
| 各分区格式/大小/内容 | **高** | blkid + 首 512 B + 整盘 dd 非零统计 |
| 3350 确实存在于电量计 IC（非 App 显示问题） | **高** | 引导器 I2C 直读 0x4A 寄存器（sdf2），Android 之前 |
| 3350 与"旧内核 recovery / 旧 ROM"相关 | **中** | 6 条 3350 记录全部来自 6.6.30/6.6.89/6.6.66 内核；但无日期 |
| 3250 是原厂 DDRC 目标值（vterm_final） | **高** | 所有 `vterm_final` 记录 + `oplus_fg_set_deep_term_volt volt=3250` |
| 模块只写过 3250/2600，没写过 3350 | **中高** | 全分区检索无 3350 写入记录；但模块可能未记录全部写入 |
| 产线老化**不是** 1758 的来源 | **高** | 出厂后 2025-10-26 计数仍为 0，且有完整递增序列 |
| **3250→3350 的确切时间点** | **无法确定** | 相关记录 RTC 全部未同步；update_engine 日志只剩 2026-09-27 之后 |
| "1970-07-22" = 2026-07-22（年份字段丢失） | **低（推测）** | 月日与最新内核构建日 2026-07-22 吻合，无直接证据 |

## 6. 复现命令

```bash
# 分区格式
adb -s <SERIAL> shell 'su -c "blkid /dev/block/sdf2 /dev/block/sdf3 /dev/block/sdf4 /dev/block/sdf5 /dev/block/sdf6 /dev/block/sde74 /dev/block/sde84"'
# 只读挂载 logfs
adb -s <SERIAL> shell 'su -c "mkdir -p /mnt/tmp_logfs; mount -t vfat -o ro /dev/block/sde74 /mnt/tmp_logfs; ls -laR /mnt/tmp_logfs"'
# 整盘 dd + 拉回
adb -s <SERIAL> shell 'su -c "dd if=/dev/block/sdf6 of=/data/local/tmp/raw/sdf6.bin bs=1M"'
adb -s <SERIAL> pull /data/local/tmp/raw/ /tmp/oxlogs/raw/
# 关键字
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs/raw3.py    # 有序 deep_term_volt / ddrc_status / uv2800 序列
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs/raw4.py    # adsp_write / 3350 上下文
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs/scan3.py   # 每个日志文件的 count / dtv / uv_thr 汇总
```
---

# 第二批：刷写前现场备份（2025-12 → 2026-09）补齐时间线

## 0. 输入与判定

工作区 5 个镜像（宿主 mtime **2026-09-26 18:43**，= 2026-09-26 18:43 GMT+8）：

| 文件 | 大小 | 非零字节 | 格式 | 对应真机分区 |
|---|---|---|---|---|
| `oplusreserve1.img` | 8 MiB | 746,985 (8.90%) | 裸区，头 `5a3ab79ffae66c7b`+`SKhynix`+`HN8T274EJKX130` | sdf2 |
| `oplusreserve2.img` | 256 MiB | 195,513,629 (72.83%) | **ext4**，UUID **`7950b9a1-fbdd-4d40-aaa6-14d5842db451`** | sdf3 |
| `oplusreserve3.img` | 64 MiB | 5,242,880 (7.81%)（仅 0x1000000–0x14F0000） | 裸区，内核日志环 | sdf4 |
| `oplusreserve4.img` | 32 MiB | **0（0.00%）** | 全 0，从未写过 | sdf5 |
| `oplusreserve5.img` | 64 MiB | 19,047,935 (28.38%) | 裸区，头 `82 0e 00 00`+`PHOENIX2.0`，内核日志环，**8 次开机** | sdf6 |

**关键判定：这确实是刷写前现场，且与真机分区不是同一份数据**

| 证据 | 备份 | 真机（第一批） |
|---|---|---|
| ext4 UUID | `7950b9a1-…` | `62e0cd6f-…` |
| ext4 **创建时间** | **Thu Jan 1 00:01:56 2026** | — |
| ext4 **最后写入** | **Sun Sep 27 02:32:31 2026** | — |
| Mount count | 293 | — |
| `oplusreserve5` 头 | `82 0e` / `97 0b` | `a9 07` / `c5 06` |
| `i2c term voltage` (sdf2/oplusreserve1) | **3060, 3060, 3060, 3060** | 3350, 3250, 2540, 3250 |
| deep_dischg_counts 最大值 | **1699** | **1758** |

⇒ 备份 = 真机被 2025-12 字库覆盖**之前**的状态；ext4 覆盖 **2026-01-01 → 2026-09-27 02:32**，正是第一批缺失的窗口。

**ROM 身份（本批新增，决定性）**：
- `oplusreserve2.img` 内 2 个 minidump 文件名：
  `SYSTEM_LAST_KMSG@…@**PJZ110_11.C.89_1890_202604292214**@2026_08_07_19_42_59.dat.gz`
  `SYSTEM_LAST_KMSG@…@**PJZ110_11.C.89_1890_202604292214**@2026_08_10_00_05_56.dat.gz`
- minidump 内 `device.info`：`version:PJZ110_11.C.89_1890_202604292214`、`serialID 0xf8d12d30`、UFS `HN8T274EJKX130`
- `recovery/.version` = `3.7.1_16-Dodge-Color597-V2.2`（第三方 recovery "Dodge"）
- 5 份 `recovery/last_log*` 的 `ro.build.version.incremental` 全部 = **1777453297284 → 2026-04-29**，slot 全部 `_a`（= C.89）
- `media/log/criticalLog/persist/critical.log` 内 `log-buildTime`：**879 条 C.86 (`PJZ110_11.C.86_1860_202603040058`, V16.0.0) → 1336 条 C.89 (`PJZ110_11.C.89_1890_202604292214`, V16.1.0)**，文件内顺序 0..878 = C.86、879..2215 = C.89
- `media/log/criticalLog/persist/critical.dat` 内还有 `1786372068166` (=2026-08-10) 与 `PJZ110_11.C.89…`

⇒ **刷写前设备运行的是 C.86（2026-03-04）→ C.89（2026-04-29）**。

---

## 1. 时间线（2025-09 → 2026-10-05）

**这张表是两批合起来的完整链**；"值"列若为 `vterm_final / term_now` 是 DDRC 四元组前两位。

| 日期（可信度） | 证据来源 | counts | cc | ratio=10c/cc | temp_idx/ratio_idx | index | vterm_final | term_now | ROM |
|---|---|---|---|---|---|---|---|---|---|
| 2025-09-09 / 09-18 | 备份 `oplusreserve1` 引导器日期行 | — | — | — | — | — | **3060**（`i2c term voltage`） | — | 出厂 PJZ110_15.0.0.851 / 15.0.0.70 |
| 2025-10-26 | `merge_kernel_log.8/.7`（在**被刷入的 2025-12 镜像**里） | 0 | 1 | 0 | — | — | **3060** | 3060 | — |
| 2025-11-03 13:16:35 UTC | 备份 `oplusreserve5` WatchDog UTC 行 | — | — | — | — | — | — | — | — |
| 2025-11-13 | `merge_kernel_log.6` | 136 | 20 | 68 | — | — | **3060** | 3060 | — |
| 2025-12-13 | `merge_kernel_log.5` | 256 | 57 | 44 | — | — | **3060** | 3060 | C.83 / 16.0.2.403 |
| 2025-12-31 16:00:38 UTC (=2026-01-01 00:00:38 GMT+8) | 备份 `oplusreserve3` WatchDog UTC 行 | — | — | — | — | — | — | — | — |
| 2026-01-01 00:00:32 | 备份 `oplusreserve3` bq28z610 寄存器转储 | — | — | — | — | — | — | — | — |
| **2026-01-01 00:01:56** | 备份 ext4 superblock **创建时间** | — | — | — | — | — | — | — | （ext4 重建） |
| 2026-03-02 14:13:47 | 备份 `oplusreserve5` bq28z610 寄存器转储 | — | — | — | — | — | — | — | C.86（build 2026-03-04） |
| 2026-03-12 17:14:31 | 备份 `oplusreserve3` 日期行 | — | — | — | — | — | — | — | — |
| **2026-03-27 21:21:14** | 备份 `oplusreserve5` **DeepDischg crux** | — | — | — | **temp[2,2] ratio[2,2]** | **0** | **2800** | 2800 | C.86 |
| **2026-03-28 03:50:38** | 备份 `oplusreserve5` **DeepDischg crux** | **763** | **173** | **44** | **temp[3,3] ratio[2,2]** | **1** | **3060** | 2800 | C.86 |
| 2026-04-01 15:23:48 | 备份 `oplusreserve3` 日期行 | — | — | — | — | — | — | — | — |
| **2026-04-29** | C.89 build 日期 / 5 份 recovery incremental | — | — | — | — | — | — | — | **C.89 (V16.1.0)** |
| （2026-04-29 之后） | 备份 `recovery/last_kmsg.4/.3/.2` | **1159** | **224** | **51** | ?（无 crux） | ? | **3150** | 3000 | C.89 |
| （再之后） | 备份 `recovery/last_kmsg.1` + `tmp_log/recovery_dmesg_log_0` | **1387** | **263** | **52** | ?（无 crux） | ? | **3150** | 3150 | C.89 |
| 2026-08-07 19:42 / 2026-08-10 00:05 | 备份 2 个 minidump 文件名 | — | — | — | — | — | — | — | C.89 |
| **2026-08-24 18:58:47** | 备份 `oplusreserve5` **DeepDischg crux** | **1625** | **314** | **51** | **temp[3,3] ratio[3,3]** | **2** | **3250** | 3210 | C.89 |
| 2026-08-27 17:19:03 | 备份 `oplusreserve5` crux | 1625 | 317 | 51 | temp[3,3] ratio[3,3] | 2 | 3250 | 3230 | C.89 |
| 2026-08-28 00:32:42 / 00:33:56 | 备份 `oplusreserve5` crux ×2 | 1625 | 317 | 51 | temp[3,3] ratio[3,3] | 2 | 3250 | 3230 | C.89 |
| 2026-08-30 15:41:00 | 备份 `oplusreserve5` crux | 1625 | 319 | 50 | temp[3,3] ratio[3,3] | 2 | 3250 | 3230 | C.89 |
| 2026-09-14 / 09-16 / 09-17 06:2x | 备份 `fs_mgr_log` / `oplusreserve1` 日期行 | — | — | — | — | — | — | — | C.89 |
| **2026-09-17 18:36–18:38** | 备份 `boot_log/boot_645|646/kernel_boot.log` | **1677** | 329 | 51 | — | — | **3250** | 3250 | C.89 |
| 2026-09-19 | 备份 `fs_mgr_log` | — | — | — | — | — | — | — | C.89 |
| 2026-09-26 15:39 / 18:30–18:32 UTC | 备份 `critical.log` / `oplusreserve3` WatchDog UTC | — | — | — | — | — | — | — | C.89 |
| **2026-09-27 02:25:04** | 备份 `boot_log/boot_647/kernel_boot.log` | **1699** | **335** | **50** | — | — | **3250** | 3250 | C.89 |
| **2026-09-27 02:30:23** | 备份 `oplusreserve3` **DeepDischg crux** | **1699** | **335** | **50** | **temp[3,3] ratio[3,3]** | **2** | **3250** | 3250 | C.89 |
| **2026-09-27 02:32:31** | 备份 ext4 superblock 最后写入 / `update_engine.19700714-124758` 末行 `[0927/023227]` | — | — | — | — | — | — | — | ← **EDL 刷写点** |
| 刷写后 | 真机 sdf4/sdf6 + 真机 ext4 | 1758 | 344 | 51 | — | — | 3250 | **3350**（无模块）/ 2540（模块） | post-flash |

---

## 2. 核心答案：3060 → 3250 何时、什么条件

### 2.1 是**两级爬升**，不是一跳

`vterm_final`（DDRC 表查出来的目标终止电压）实测取值序列：

```
3060  —— counts 0 … 763     (2025-10-26 … 2026-03-28)
3150  —— counts 1159 … 1387  (2026-04-29 之后 … 2026-08-24 之前)
3250  —— counts 1625 … 1758  (2026-08-24 … 至今)
```

- **3060 的最后一次确认：2026-03-28 03:50:38**（counts=763, cc=173, ratio=44）
- **3250 的第一次确认：2026-08-24 18:58:47**（counts=1625, cc=314, ratio=51）
- **中间的 3150：counts=1159（cc=224, ratio=51）与 counts=1387（cc=263, ratio=52）**，
  这两笔只存在于 `recovery/last_kmsg*`（RTC 未同步，无日历时间），但其 recovery build 全部是 **C.89 = 2026-04-29**，所以它们 **必然发生在 2026-04-29 之后**。

⇒ **3060 → 3150 的时点被夹在 2026-03-28 03:50:38 与 2026-04-29 之间**（counts 763→1159）；
  **3150 → 3250 的时点被夹在 2026-04-29 与 2026-08-24 18:58:47 之间**（counts 1387→1625）。

### 2.2 换表的直接证据（crux 记录，带日期）

内核日志里有带完整表索引的记录（`oplus_chg_track_pack_dcs_info`）：

```
【2026-03-27 21:21:14】flag_reason@@DeepDischgInfo$$time@@[2026-03-27 21:21:14]$$track_reason@@vote
   $$temp_p@@2$$temp_n@@2$$ratio_p@@2$$ratio_n@@2$$vstep@@20$$vterm_final@@2800$$term_now@@2800$$index@@0
【2026-03-28 03:50:38】…$$temp_p@@3$$temp_n@@3$$ratio_p@@2$$ratio_n@@2$$vstep@@20$$vterm_final@@3060$$term_now@@2800$$index@@1
              …同时刻另有 $$dischg_counts@@763$$cc@@173$$ratio@@44
【2026-08-24 18:58:47】…$$temp_p@@3$$temp_n@@3$$ratio_p@@3$$ratio_n@@3$$vstep@@20$$vterm_final@@3250$$term_now@@3210$$index@@2
              …$$dischg_counts@@1625$$cc@@314$$ratio@@51
【2026-08-27 17:19:03】…temp[3,3] ratio[3,3] vterm_final@@3250 term_now@@3230 index@@2  counts=1625 cc=317 ratio=51
【2026-08-28 00:32:42】…temp[3,3] ratio[3,3] vterm_final@@3250 term_now@@3230 index@@2  counts=1625 cc=317 ratio=51
【2026-08-28 00:33:56】…temp[3,3] ratio[3,3] vterm_final@@3250 term_now@@3230 index@@2  counts=1625 cc=317 ratio=51
【2026-08-30 15:41:00】…temp[3,3] ratio[3,3] vterm_final@@3250 term_now@@3230 index@@2  counts=1625 cc=319 ratio=50
【2026-09-27 02:30:23】…temp[3,3] ratio[3,3] vterm_final@@3250 term_now@@3250 index@@2  counts=1699 cc=335 ratio=50
```

**温度桶固定为 3，ratio 桶 2 → 3 时，`vterm_final` 从 3060 变成 3250。** 这就是"换表"。

### 2.3 与"counts 增长驱动换表"机制的吻合 / 矛盾

**吻合的部分（结构上被证实）**
1. `ratio = 10×counts/cc` 这个式子**成立**：日志中的 `ratio` 字段与 `floor(10*counts/cc)` 完全对上
   （763/173→44.1 记 44；1625/314→51.75 记 51；1699/335→50.7 记 50；1387/263→52.7 记 52）。
2. 表确实是**二维查表**：crux 记录直接打印 `temp[p,n]` 与 `ratio[p,n]` 两个索引，`vstep=20`。
3. **温度桶不变、ratio 桶跨档 → 值从 3060 换到 3250**，与预测一致。
4. 桶界在 ratio **44 与 51 之间**（3060 在 ratio 44；3250 在 ratio 50–51）。

**与预测不完全一致 / 需要修正的部分**
1. **不是一次跳到 3250**：中间还存在 **3150** 这一档（counts 1159/1387）。用户的"3060→3250 一次换表"需要改成 **3060 → 3150 → 3250**。
2. **3150 那几笔没有 crux 记录**，因此无法判断 3150 是：
   (a) 同一个 ratio 桶 3 但**另一个温度桶**的表元（因为 counts=1387/ratio=52 与 counts=1625/ratio=51 的 ratio 几乎相同却给出 3150 与 3250，说明**温度桶必然不同**），
   (b) 还是第三档表。
   → **需要用 RE-A/RE-C 里已经还原的 `ddrc_strategy` / `ddb_curve` 表结构去核对**：
   若表为 `table[temp_bucket][ratio_bucket]`，则应能在表中找到 `(?, 3)=3150` 与 `(3, 3)=3250`、`(3, 2)=3060`、`(2, 2)=2800` 四个格。
3. `index` 字段与值同步变化（0→2800、1→3060、2→3250），**index 与 ratio 桶在此窗口内是同向移动的**，无法从日志区分"是 ratio 桶驱动"还是"index/策略阶段驱动"。但因为 temp 桶固定，**ratio 桶是最可能的自变量**。
4. 增大 counts **不一定单调抬升**：2026-03-27（temp2, ratio2）给出 **2800**，比 2026-03-28（temp3, ratio2）的 **3060** 更低 → 温度桶的影响可达 260 mV，**温度是不可忽略的第二维**。

---

## 3. 这段窗口里出现过 3350 吗？

**未出现。** 明确结论 + 检索范围：

- 逐个文件统计（整盘全文匹配，不只是文本区）：

| 文件 | `3350` 命中 | 全部命中的真实上下文 |
|---|---|---|
| `oplusreserve1.img` | 8 | 只有 2 种：`EFI_GetBootToHlosThd param 3350 -100 50 50 50 50 3000 3400 3150 0 0 3400 3050`（固定入参 ×4）与 `threshold_logo_mv 3350 to 3150` / `… to 3050`（引导器阈值 ×4） |
| `oplusreserve2.img` | 13 | 仅 `recovery/last_kmsg.3`(2)、`recovery/last_kmsg.4`(1) 的 **内核 uptime 小数**（如 `0.693350`、`0.335008`）与 `security_behavior_log` 的 `20260815_133350` 时间戳 |
| `oplusreserve3.img` | 1 | `horae` 背光数字串 `back:37349,back_1:38305…` |
| `oplusreserve4.img` | **0** | 全 0 分区 |
| `oplusreserve5.img` | 63 | **全部是内核 uptime 小数**（`0.183350`、`4.335091`、`1.833509`、`6.335049`、`3.503350` …） |
| ext4 dump（159 MB，45 文件） | 4 | 同上，均为 uptime 小数 / 时间戳 |

- **没有任何一处是电量计终止电压。**
- 对照：`oplusreserve1.img` 的 `i2c term voltage`（引导器 I2C 直读电量计 0x4A）**4/4 全是 3060**。
- ⇒ 在 **2025-12 → 2026-09-27 02:32** 这段窗口里，电量计终止电压**从未取过 3350**；3350 只出现在刷写之后（真机 sdf2）。

**旁证（非主证）**：引导器另一个值 `threshold_logo_mv 3350 to X` 也随之上移：
- 备份（term=3060）：`3350 to 3150`(×2)、`3350 to 3050`(×2)
- 刷写后真机（term=3350/3250/2540/3250）：`3350 to 3400`(×2)、`3350 to 3300`(×2)

---

## 4. ROM / OTA 事件对照

| 日期 | 事件 | 来源 |
|---|---|---|
| 2025-09-09 / 09-18 | 出厂（PJZ110_15.0.0.851 / 15.0.0.70），厂测老化 | 备份 `oplusreserve1` 日期行；真机 `factory/` |
| 2025-10-26 22:54 / 23:12 | OTA 运行（写入 merge_kernel_log.8/.7） | 被刷入镜像里的 `update_engine_log` |
| 2025-11-13 16:53 | OTA 运行 | 同上 |
| 2025-12-07 | **C.83 / 16.0.2.403** OTA | `merge_kernel_log.5` 内 `PJZ110_11.C.83_1830_202512070008` |
| 2025-12-13 01:00 | OTA 运行 | `merge_kernel_log.5` mtime |
| 2025-12-31 16:00:38 UTC（=2026-01-01 00:00:38 GMT+8） | 一次重启；**86 秒后 ext4 被重建**（00:01:56） | 备份 `oplusreserve3` WatchDog UTC + ext4 superblock |
| **2026-03-04** | **C.86 / V16.0.0** build（`PJZ110_11.C.86_1860_202603040058`） | 备份 critical.log 879 条 |
| **2026-04-29** | **C.89 / V16.1.0** build（`PJZ110_11.C.89_1890_202604292214`） | 备份 critical.log 1336 条 + 5 份 recovery incremental + 2 个 minidump 文件名 |
| 2026-08-07 19:42 / 2026-08-10 00:05 | 2 次异常重启，产生 minidump（C.89） | 备份 `media/log/minidump/` |
| 2026-08-12 23:29 | `hang_oplus` 目录活动 | 备份目录 mtime |
| 2026-09-17 06:25:47 / 18:36:39 / 18:38:10 | 3 次开机，产生 boot_log | 备份 `media/log/boot_log/` 文件名 |
| 2026-09-27 02:25:04 / 02:30 | 最后 2 次开机（C.89） | 备份 `boot_log/boot_647,648` |
| **2026-09-27 02:32:31** | ext4 最后写入；`update_engine` 退出码 0（`CleanupPreviousUpdateAction`） | 备份 ext4 superblock / `update_engine.19700714-124758` |
| 2026-09-27（之后） | **EDL(9008) 刷入 2025-12 全字库**；随后 OTA C.93→C.94→F.04→F.05 | 真机 `update_engine_log` |

**与电压变化的对齐**：
- C.86 期间（2026-03-04 ~ 2026-04-29）确认值是 **3060**（2026-03-28 crux）与 **2800**（2026-03-27 crux，另一温度桶）。
- **C.89 期间（2026-04-29 ~ 2026-09-27）值从 3150 走到 3250**：counts 1159/1387 → 3150（recovery build 全是 C.89），counts 1625 → 3250（2026-08-24 起）。
- ⇒ **刷 ROM 与换表没有因果关系**：C.86→C.89 的系统升级期间表还是 3060；换表发生在 C.89 内部（2026-04-29 ~ 2026-08-24），由 counts/cc 的 ratio 跨档触发。

**未发现的**：
- 备份里 **没有任何 `update_engine.*` OTA payload 记录**（唯一一份 `update_engine.19700714-124758` 只是 A/B 引擎的清理动作，无版本串）→ 说明 **C.86→C.89 是本地/整包方式，不是 A/B OTA**，或日志被轮转掉。
- 备份里 **没有 FFU 记录**（`last_ffu` 0 字节、`last_ffu_log_all` 内容与第一批一致："fws is empty"）。
- 备份里 **没有 `DCS/kevent` 目录**（`DCS` 位于 /data 分区，不在 oplusreserve2）。

---

## 5. 引导器固定入参复核（题目第 4 问）

`EFI_GetBootToHlosThd param …` 在 5 个备份文件里的出现情况：

| 文件 | 出现次数 | 唯一取值数 |
|---|---|---|
| `oplusreserve1.img` | **4** | **1** |
| `oplusreserve3.img` | 0 | — |
| `oplusreserve4.img` | 0 | — |
| `oplusreserve5.img` | 0 | — |

4 次全部相同：
```
EFI_GetBootToHlosThd param 3350 -100 50 50 50 50 3000 3400 3150 0 0 3400 3050
```
（出现偏移 0x43cfad / 0x443fad / 0x44afab / 0x451fb4，与 4 次开机的 `i2c term voltage` 一一对应）

**结论：再次确认它是引导器固定入参**，与电量计无关。对照 `oplusreserve1.img` 同一段日志里 `i2c term voltage` 4 次全为 **3060** —— **同一个 3350 入参加 3060 的电量计值**，铁证。
附带：`EFI_GetBootToHlosThd thd_mv` 是**变化的**（`6100 … 0 1 2 2 0` / `6300 … 0 1 0 0 0`），说明这段日志里变的是 thd_mv 而不是上面的 param 串。

---

## 6. `oplus_fg_set_deep_term_volt` 原厂写入记录（题目第 5 问）

| 数据源 | `set_deep_term_volt rc=…, volt = …` | 取值 |
|---|---|---|
| 备份 `oplusreserve1.img` | **0** | — |
| 备份 `oplusreserve2.img` | **0** | — |
| 备份 `oplusreserve3.img` | **0** | — |
| 备份 `oplusreserve4.img` | 0 | — |
| 备份 `oplusreserve5.img` | **0** | — |
| 备份 ext4 dump（159 MB，45 文件） | **0** | — |
| 对照：刷写后真机 `sdf4.bin` | 1（另有 1 条 `oplus_fg_set_deep_term_volt` 标签行） | `3250` |
| 对照：刷写后真机 `recovery/last_kmsg`（在真机 ext4 内） | 1 | `3250` |

**结论：刷写前窗口（2025-12 → 2026-09-27）内，内核从不记录（或从不执行）deep term voltage 的写入，只做读取**（`deep_term_volt=` 读：ext4 img 48 次、reserve3 9 次、reserve5 107 次）。
`oplus_fg_set_deep_term_volt` 这个写入日志是**刷写后的内核才出现的，而且值恒为 3250**（= DDRC 目标），一次 3350 都没有。

---

## 7. 本批结论对第一批的修正

| 第一批结论 | 本批修正 |
|---|---|
| "3250→3350 的确切时点无法确定" | 保持"3350 时点无法确定"，但**3060→3150→3250 的时点已确定到区间**（见 §2.1），且**3350 在刷写前从未出现** |
| "产线老化不是 1758 的来源" | **加强**：备份里 counts 序列 763→1159→1387→1625→1665→1677→1699 全部是使用期累积，且 dated 记录显示 2026-03-28 才 763 |
| "3350 与旧内核 recovery 相关" | 部分修正：备份里 recovery 全是 **6.6.89-g7e1f（Dec 2025）**，值域是 3000/3150/3250，**没有 3350**；3350 只在真机（刷写后 + 用户模块存在）出现 |
| "模块只写过 3250/2600" | **加强**：刷写前窗口根本没有写入日志；模块是唯一有 `adsp_write` 记录的一方 |

---

## 8. 复现命令

```bash
# ext4 元数据（创建/最后写入时间、UUID）
dumpe2fs -h <EXTERNAL>/oplusreserve2.img
# 整盘递归导出（只读）
mkdir -p /tmp/oxlogs2/x2
debugfs -R "rdump / /tmp/oxlogs2/x2" <EXTERNAL>/oplusreserve2.img
# 裸区按槽分析（内核版本 / counts / cc / 四元组 / 日期行）
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/slots.py
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/align.py
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/dctx.py
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/final2.py    # 3350 上下文 / crux / 写入记录
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/tuples.py   # 全量 (cc,counts,vterm_final,term_now) 元组
```

## 9. 本批置信度

| 结论 | 置信度 | 依据 |
|---|---|---|
| 5 个镜像 = 刷写前现场，覆盖 2026-01-01→2026-09-27 02:32 | **高** | ext4 UUID 不同 + superblock 创建/最后写入 + 真机值域不同 |
| 刷写前 ROM = C.86 → C.89 | **高** | minidump 文件名 + device.info + recovery incremental + critical.log buildTime |
| `vterm_final` 有 3060/3150/3250 三档 | **高** | 带日期的 crux 记录 + ddrc_status 四元组 |
| 3060 最后确认于 2026-03-28、3250 首次确认于 2026-08-24 | **高** | 带完整日历时间的 crux 记录 |
| 3150 发生在 2026-04-29 之后 | **中高** | recovery build incremental = 2026-04-29（C.89），5 份全是 |
| "temp 桶固定时 ratio 桶 2→3 触发 3060→3250" | **高**（结构）/ **中**（因果独立性，因 index 与 ratio 同步） | crux 记录的 temp/ratio 索引 |
| 3150 属于"另一个温度桶" | **中（假说）** | ratio 51~52 同时对应 3150 与 3250，必然有第二维不同；但无 crux 证据 |
| 刷写前窗口内 3350 未出现 | **高** | 5 个镜像 + 159 MB ext4 dump 全文匹配，全部命中都是 noise |
| `EFI_GetBootToHlosThd param` 固定 | **高** | 4/4 唯一取值 1 |
| 刷写前无 `set_deep_term_volt` 写入日志 | **高** | 6 个数据源全 0 |
| "1970-xx-xx" 类时间戳不可用 | **高** | 与 UTC WatchDog 行直接冲突（同一次开机既报 1970-07-14 又报 2026-09-27） |
---

# 第三批追加：2800（社区 dtbo 解容）阶段 + 改 dtbo 痕迹 + 三类值归类

> 触发：用户补充“2025-12 → 2026-09 期间用过社区『原始解容方法』——改 dtbo 里的 ddrc 曲线（删掉 ddrc_strategy，或把不同温度段的数值全改成 2800）”。
> 因此本批把 **2800 = 社区 dtbo 方法标记**、**2540 = 本模块标记**、**3060/3250 = 原厂** 分开归类，并复核解容期是否遮住了 3150 档。

## 1. 改 dtbo / 刷 dtbo 的痕迹 —— **找到了（硬证据）**

来源：`oplusreserve1.img»（引导器日志环，= 刷写前现场的 sdf2）

### 1.1 AVB 签名异常（自定义镜像的直接证据）
```
@0x43fb4b  avb_slot_verify.c:888: ERROR: dtbo_a: Public key used to sign data does not match
          key in chain partition descriptor.          <-- 出现 4 次
@0x43fd90  avb_slot_verify.c:504: ERROR: init_boot_a: Hash of data does not match digest in descriptor.
@0x43fe1b  avb_slot_verify.c:504: ERROR: vendor_boot_a: Hash of data does not match digest in descriptor.
@0x43fcaa  vbmeta_header:1767225600, stored_index :1754006400.
```
- `dtbo_a» **用非 OEM 公钥签名** → 该分区被**重新签名/替换**（自定义 dtbo）
- 同时 `init_boot_a»、`vendor_boot_a» 的 **hash 与描述符不符** → 自定义 init_boot（root 用）与 vendor_boot

### 1.2 槽位分布
| 关键字 | 次数 |
|---|---|
| `dtbo_a» | 16 |
| **`dtbo_b»** | **0** |
| `Load Image dtbo_a» | 12 |
| **`Load Image dtbo_b»** | **0** |
| `dtbo_found_count» | 8 |
| `Public key used to sign data does not match» | 4 |

→ 设备**只加载 a 槽的 dtbo**，且 a 槽是自定义签名。设备侧 `ro.boot.slot_suffix=_b»（当前系统在 b 槽），但 dtbo 读的是 `dtbo_a»。

### 1.3 引导器启动历史表（`oplusreserve1.img» @0x49bf00，新→旧）
```
===last boot reason : hard_reset;Boot bootloader [2026-08-30 15:39:41]
===last boot reason : hard_reset;Boot bootloader  reboot,bootloader from pid: 2908 (system_server) [2026-08-30 15:41:08]
===last boot reason : hard_reset;Boot bootloader [2026-08-30 15:41:50]
===last boot reason : hard_reset;Boot bootloader [2026-09-14 20:31:32]
===last boot reason : hard_reset;Boot bootloader  reboot,bootloader from pid: 26070 (reboot) [2026-09-14 20:40:26]
===last boot reason : hard_reset;Boot bootloader [2026-09-14 20:40:36]
===last boot reason : hard_reset;Boot reboot,shell  reboot,shell from pid: 12496 (/system/bin/reboot) [2026-09-17 06:22:53]
===last boot reason : hard_reset;Boot bootloader  reboot,bootloader from pid: 16421 (reboot) [2026-09-17 06:25:55]
===last boot reason : hard_reset;Boot bootloader [2026-09-17 06:26:14]
===last boot reason : hard_reset;Boot bootloader [2026-09-17 06:27:45]
===last boot reason : hard_reset;Boot KPDPWR_N  reboot,shell from pid: 13703 (/system/bin/reboot) [2026-09-17 18:36:47]
===last boot reason : hard_reset;Boot bootloader  reboot,bootloader from pid: 14798 (reboot) [2026-09-17 18:38:18]
===last boot reason : hard_reset;Boot bootloader [2026-09-17 18:38:46]
===last boot reason : hard_reset;Boot bootloader [2026-09-19 19:37:32]
===last boot reason : hard_reset;Boot bootloader [2026-09-27 02:17:24]
===last boot reason : hard_reset;Boot bootloader  reboot,bootloader from pid: 17337 (/system/bin/reboot) [2026-09-27 02:25:13]
===last boot reason : reboot,factory_reset [2026-01-01 00:00:31]        <-- 表尾 = 最早
```
- **多次 `reboot,bootloader»**（2026-08-30 15:41:08、2026-09-14 20:40:26、2026-09-17 06:25:55、2026-09-17 18:38:18、2026-09-27 02:25:13）→ 主动进 fastboot/bootloader 刷分区
- **`last boot reason : reboot,factory_reset [2026-01-01 00:00:31]»** → 2026-01-01 00:00:31 一次**恢复出厂**；**85 秒后** ext4 被重建（superblock `Filesystem created: Thu Jan  1 00:01:56 2026»）→ 这就是“缺失窗口”的起点

### 1.4 反面证据（**避免误判**，重要）
- `ro.boot.dtbo_idx=5»：**备份的 recovery 日志里是 5**，**刷写后的真机也是 5** → **dtbo_idx=5 是本项目正常值，不能当作“改过 dtbo”的标志**
- 真机 `ro.boot.verifiedbootstate=orange»、`ro.boot.flash.locked=0»、`ro.boot.vbmeta.device_state=unlocked»、`ro.boot.veritymode=enforcing»、`avb_version=1.3» → **引导器已解锁**，所以上面的 AVB 失败**不会阻止启动**（这解释了为什么换了 dtbo 还能正常开机）
- 备份里**没有**真正的 EDL/9008 痕迹：`9008»/`qdl» 命中全部落在二进制/压缩块里（`oplusreserve2.img»）或 `PMIC PON log: PON Trigger: HARD_RESET/USB_CHARGE» 这类行里（`oplusreserve5.img»）

---

## 2. 2800 阶段（社区 dtbo 解容）—— 定位与指纹

### 2.1 出现范围
| 文件 | `vterm_final@@2800» | `term_now@@2800» | `deep_term_volt=2800» | `set uv_thr=2800» | `[2800, 2800, 2800, 2800]» |
|---|---|---|---|---|---|
| `oplusreserve1.img» | 0 | 0 | 0 | 0 | 0 |
| `oplusreserve2.img» | 0 | 0 | 0 | 0 | 0 |
| `oplusreserve3.img» | 0 | 0 | 0 | 0 | 0 |
| **`oplusreserve5.img»** | **1** | **3** | **4** | **1** | **3** |

→ 2800 只出现在内核日志环 `oplusreserve5»，引导器/主料区里没有。

### 2.2 唯一带日历时间的 2800 记录
```
oplusreserve5.img @0x15e5d1a
flag_reason@@DeepDischgInfo$$time@@[2026-03-27 21:21:14]$$track_reason@@vote
  $$temp_p@@2$$temp_n@@2$$ratio_p@@2$$ratio_n@@2$$vstep@@20
  $$vterm_final@@2800$$term_now@@2800$$index@@0
```

### 2.3 2800 记录全部绑定在同一组 counts/cc
全部 2800 相关记录的 DDRC 五元组都是 `[0, 172, 763, 44, 0]»：

```
@0x15ae3f2  deep_term_volt=2800 + ddrc_status [0, 0][2800, 2800, 2800, 2800] [0, 172, 763, 44, 0]
@0x15ae46c  同上
@0x15b271b  update_vbat_uv [2800, 0] -> set uv_thr=2800
@0x15ba4d5  deep_term_volt=2800 + [2800, 2800, 2800, 2800] [0, 172, 763, 44, 0]
@0x15ba54f  同上
@0x15c4400  deep_term_volt=2800 + [2800, 2800, 2800, 2800] [0, 172, 763, 44, 0]
@0x15c447a  同上
@0x15e5d1a  crux 2026-03-27 21:21:14  vterm_final=2800 term_now=2800
```

### 2.4 改过曲线的**指纹**：四元组偏移消失
| 数据 | 四元组 | 元素0 − 元素2 | 元素1 − 元素3 |
|---|---|---|---|
| 原厂（3060 档） | `[3060, 2800, 3000, 2740]» | 60 | 60 |
| 原厂（3150 档） | `[3150, 3000, 3100, 2950]» | 50 | 50 |
| 原厂（无降档） | `[3150, 3150, 3100, 3100]»、`[3250, 3250, 3200, 3200]» | 50 | 50 |
| **2800 阶段** | **`[2800, 2800, 2800, 2800]»** | **0** | **0** |

→ 原厂曲线里第 3/4 个元素固定比第 1/2 个低 50（或 60）mV；**2800 阶段四个元素全等**，即下探余量被抹平 —— 与“把曲线数值整段改成 2800”的手改行为一致。**“偏移消失”可作改过曲线的判据。**

### 2.5 2800 阶段的终点（有日期）与起点（只能给区间）
- **终点：确定在 2026-03-28 03:50:38 之前**
  ```
  oplusreserve5.img  crux  2026-03-28 03:50:38
     temp_p@@3$$temp_n@@3$$ratio_p@@2$$ratio_n@@2$$vstep@@20
     $$vterm_final@@3060$$term_now@@2800$$index@@1$$dischg_counts@@763$$cc@@173$$ratio@@44
  ddrc_status [3060, 2800, 3000, 2740] || [172, 173, 763, 44, 0]   （×1）
  ```
  → **DDRC 目标已回到原厂 3060，而电量计 IC 仍残留 2800**（cc 从 172 走到 173）。
- **起点：无法确定**。下界是 counts=256 / cc=57 / 2025-12-13（当时 vterm_final=3060，原厂）；上界是 2026-03-27 21:21:14。也就是说 **2800 阶段落在 counts 256 → 763 之间**，且最后一次出现是 2026-03-27。
- 补充约束：2800 记录的 cc=**172**，而 2026-03-28 是 cc=**173** → 说明 dtbo 还原与 2800 出现之间只跨了 1 个循环计数，**是一个很短的窗口**（但 cc 不一定每天 +1，所以不能换算成天数）。

---

## 3. 三类值的归类（本批实测，可直接用作判据）

| 值 | 备份（2025-12 → 2026-09-27） | 真机（刷写后） | 归类判定 |
|---|---|---|---|
| **2800** | `vterm_final=2800» **且** `term_now=2800»（目标本身被改）；出现于 counts=763/cc=172；日期 2026-03-27 | `deep_term_volt=2800» **0 次** | **社区 dtbo 方法**（目标被改） |
| **2540** | **完全没有**：`term_now@@2540»=0、`deep_term_volt=2540»=0（5 个镜像 + 159 MB ext4 dump 全 0；131 个 “2540” 命中全是线程号 `T2540»／模块长度等噪声） | sdf6 `term_now@@2540»×6；sdf4/sdf6 `deep_term_volt=2540»×8/×15 | **本模块（uv2800）专属标记；刷写前根本不存在** |
| **3060 / 3250** | 3060 大片（2025-10-26 … 2026-03-28）；3250 从 2026-08-24 起 | 3250 大片 | 原厂（DDRC 正常计算） |
| **3150** | counts 1159（cc 224）与 counts 1387（cc 263），均 >2026-04-29 | 0 次 | 原厂中间档（以 `vterm_final» 形式出现） |

**判据总结（本批实测可直接用）**
- `vterm_final ≈ term_now» 且差为 **0** → dtbo 手改（目标被改）
- `vterm_final − term_now = 260» → **模块**（目标未改，IC 被写成 target−260）
  实测真机：`vterm_final=3250 / term_now=2540»（3250−260=2540 ✓）
- `vterm_final − term_now ∈ {0, 20, 40}» 且四元素偏移 50/60 → **原厂 DDRC 的降档行为**

---

## 4. 解容期有没有遮住 3150 档？——**没有**

用户担心“如果解容期横跨了我们预测的 3150 档，那一段的 3150 就被 2800 遮住了”。实测结论：**未遮蔽**，两条独立证据：

1. **counts/cc 不在同一段**
   - 2800 组：**counts=763，cc=172**
   - 3150 组：**counts=1159（cc=224）** 与 **counts=1387（cc=263）**
   - cc 从 172 走到 224/263，counts 从 763 走到 1159/1387 → **3150 必然发生在 2800 阶段之后**
2. **3150 是 `vterm_final»（DDRC 目标）而不是 IC 实持值**
   ```
   [3150, 3000, 3100, 2950] || [222, 224, 1159, 51, 0]   <- vterm_final = 3150
   [3150, 3150, 3100, 3100] || [0, 263, 1387, 52, 0]     <- vterm_final = 3150
   ```
   → 用 `vterm_final» 判档位，**完全不受“IC 被模块/解容写过”的影响**（这一点与用户的要求一致，本批即按此判）。

---

## 5. 修正后的完整值序列（含解容期）

```
3060   counts 0 – 763   cc 1 – 173     2025-10-26 … 2026-03-28     原厂
  |
  +-- 2800  【社区 dtbo 解容】counts 763  cc 172   最后一次 2026-03-27 21:21:14
  |        (vterm_final=2800 且 term_now=2800；ddrc 四元组 [2800,2800,2800,2800])
  |        -> 2026-03-28 03:50:38 已还原：vterm_final=3060、term_now 残留 2800
  |
3060   counts 763  cc 173     2026-03-28 03:50:38                   原厂（已还原）
  |
  +-- 换档（ratio 桶 2 -> 3）
  |
3150   counts 1159 – 1387  cc 224 – 263   >2026-04-29（recovery build = C.89）  原厂中间档
  |
  +-- 换档
  |
3250   counts 1625 – 1758  cc 314 – 344   2026-08-24 18:58:47 -> 2026-09-27 02:30:23  原厂
  |
  +-- 2026-09-27 02:32 EDL 刷入 2025-12 全字库 ==> 真机：vterm_final 仍 3250，
        term_now 变为 3350（无模块）/ 2540（模块）—— 【2540 与 3350 都只在刷写后出现】
```

**回答用户第 3 问的两种可能**：既不是 `3060 → 2800 → 3250»，也不是 `3060 → 2800 → 3060 → 3250»（少了中间档），实测是
```
3060 -> 2800（解容）-> 3060（还原）-> 3150 -> 3250
```

---

## 6. 与“counts 增长驱动换表”机制的关系（本批更新）

| 观测 | 对机制的意义 |
|---|---|
| 2800 阶段出现在 **ratio=44、ratio 桶 idx=2**（与 3060 同桶） | **解容期没有落到桶 3**，因此**没有遮住 3150/3250 的换档证据** |
| 原厂跨档点仍在 **ratio 44（3060）→ ratio 50/51（3250）之间** | 与第二批结论一致 |
| `temp_p/temp_n» 是独立维（2026-03-27 = temp[2]、2026-03-28 = temp[3]，同一 ratio 桶 2 却给 2800 与 3060） | **温度桶影响可达 260 mV**，判断“原厂值何时跨档”必须固定温度桶或用 `vterm_final» 序列 |
| 2800 伴随 `index=0»，3060 伴随 `index=1»，3250 伴随 `index=2» | index 与 ratio 桶同向；**本批仍无法从日志区分二者谁是自变量**（需 RE-A/RE-C 的表结构核对） |

**一个必须写清的替代解释**：`(temp2, ratio2) = 2800» 也可能是**原厂表的自然格子**——
已知 `(3,2)=3060»、`(3,3)=3250»，若表单调，`(2,2)=2800» 落在更低温度档上是讲得通的。
本批能证明的是：**“目标值被改写”这一点确定（`vterm_final» 与 `term_now» 同时为 2800、且四元组偏移归零），且窗口与 AVB `dtbo_a» 签名异常的时间段吻合**；但 **“2800 完全由社区 dtbo 造成”无法从日志单独证明**——只有 1 条 2800 的 crux，且用户描述的“不同温度段全部改成 2800”若成立，应还能看到 `temp[3]» 档也是 2800（实测 2026-03-28 的 `(3,2)» 已经是原厂 3060，可能是 dtbo 已还原）。

---

## 7. 本批置信度

| 结论 | 置信度 | 依据 |
|---|---|---|
| 备份窗口内存在**自定义 dtbo**（非 OEM 签名） | **高** | 引导器 AVB `dtbo_a: Public key ... does not match» ×4 |
| 同时存在自定义 `init_boot»、`vendor_boot» | **高** | AVB `init_boot_a»/`vendor_boot_a» hash 不符 |
| 2026-01-01 00:00:31 一次 `factory_reset»，85 s 后 ext4 重建 | **高** | 引导器启动历史表 + ext4 superblock 创建时间 |
| 多次主动进 bootloader（≥5 次 `reboot,bootloader»） | **高** | 引导器启动历史表 |
| `dtbo_idx=5» 不是改 dtbo 的标志 | **高** | 备份与真机同为 5 |
| 2800 阶段**终点**在 2026-03-28 03:50:38 之前 | **高** | 带日历时间的 crux 记录 |
| 2800 阶段**起点** | **无法确定**（区间 counts 256–763，2025-12-13 → 2026-03-27） | 缺该期间的 DCS crux |
| **2540（模块标记）在刷写前完全不存在** | **高** | 6 个数据源全文匹配，真实命中 0 |
| 解容期**没有**遮蔽 3150 档 | **高** | cc 172 → 224/263 单调 + 3150 取 `vterm_final» |
| 2800 = 社区 dtbo 方法（而非原厂表自然格） | **中** | 目标被改确定；归因给 dtbo 只有时间吻合 + AVB 异常，无直接日志 |

## 8. 本批复现命令

```bash
# 引导器 AVB / dtbo / 启动历史（自定义 dtbo 痕迹）
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/b5.py
# 2800 阶段定位 + 三类值归类 + 2540 检查
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/b2.py
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/b6.py
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/b7.py
# 全部 crux（temp/ratio/vterm_final/index）与 ddrc 四元组全量
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/b3.py
# 真机对照
adb -s <SERIAL> shell 'su -c "getprop ro.boot.dtbo_idx; getprop ro.boot.verifiedbootstate; getprop ro.boot.slot_suffix"'
```
---

# 第四批：按代码级规则复核时间线（成对样本）

> 依据：子代理 B §12 已证实的驱动规则
> ```
> region  = ratio(item0x1e 与 [20,30,50,70,90] 升序比较，b.hs 无符号 >=，边界归上档)
>           <20→0; 20≤r<30→1; 30≤r<50→2; 50≤r<70→3; 70≤r<90→4; r≥90→5
> index_t = item0x1f(<4 直接用)，否则 temp 与 [-50,100,350] 比较(b.le 归下档)：
>           ≤-5.0→0; (-5,10]→1; (10,35]→2; >35→3
> k       = max{ i : row[i].f0 − count_cali ≤ cc }   （含等号，取最后一行）
> 值      = 表[region][index_t] 的 row[k].vbat1
> ```
> **ratio / 温度 / cc 三者各自都能单独抬档。**

## 0. 先修正上一批的一处错误读法（必须更正）

上一批我写过“3060：counts 0~763，cc 57~172”。**这是把两个不同时刻的样本并成一个区间，属于无效读法。**
实测数据里**不存在** `(counts=763, cc=57)» 这条记录。若真存在，按规则 ratio=10·763/57=133 → **region 5**，值就不可能还是 3060。
本批一律只用**同一条记录内齐全**的成对样本重排。以下所有结论都标注是否成对。

## 1. 成对样本清单

筛选条件：同一条日志里同时给出 **counts 与 cc**，且自洽校验 `ratio == floor(10·counts/cc)» 通过。
共 **18 条自洽成对样本**（全部通过校验，无一例外 —— 也反证 ratio 字段就是 10·counts/cc 取整）。

| # | cc | counts | ratio | **region** | count_cali | **vterm_final** | term_now | index_t | 来源 / 时间 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 0 | 0 | **0** | 0 | 3060 | 3060 | 未知 | 真机ext4/`merge_kernel_log.7» 2025-10-26 |
| 2 | 20 | 136 | 68 | **3** | 0 | 3060 | 3060 | 未知 | 真机ext4/`merge_kernel_log.6» 2025-11-13 |
| 3 | 57 | 256 | 44 | **2** | 0 | 3060 | 3060 | 未知 | 真机ext4/`merge_kernel_log.5» 2025-12-13 |
| 4 | **172** | **763** | **44** | **2** | 0 | **2800** | 2800 | **2** | 备份 `oplusreserve5.img»；crux **2026-03-27 21:21:14** |
| 5 | **173** | **763** | **44** | **2** | 172 | **3060** | 2800 | **3** | 备份 `oplusreserve5.img»；crux **2026-03-28 03:50:38** |
| 6 | **224** | **1159** | **51** | **3** | 222 | **3150** | 3000 | 未知 | 备份 `oplusreserve2.img»（recovery/last_kmsg.2/.3/.4） |
| 7 | **263** | **1387** | **52** | **3** | 0 | **3150** | 3150 | 未知 | 备份 `oplusreserve2.img»（recovery/last_kmsg.1） |
| 8 | **314** | **1625** | **51** | **3** | 310 | **3250** | 3210 | **3** | 备份 `oplusreserve5.img»；crux **2026-08-24 18:58:47** |
| 9 | 316 | 1625 | 51 | 3 | 315 | 3250 | 3230 | 未知 | 备份 `oplusreserve5.img» |
| 10 | 317 | 1625 | 51 | 3 | 315 | 3250 | 3230 | **3** | 备份 `oplusreserve5.img»；crux 2026-08-27 17:19:03 / 08-28 00:32:42 / 00:33:56 |
| 11 | 319 | 1625 | 50 | 3 | 315 | 3250 | 3230 | **3** | 备份 `oplusreserve5.img»；crux 2026-08-30 15:41:00 |
| 12 | 327 | 1665 | 50 | 3 | 0 | 3250 | 3250 | 未知 | 备份 `oplusreserve5.img» |
| 13 | 329 | 1677 | 50 | 3 | 0 | 3250 | 3250 | 未知 | 备份 `oplusreserve5.img»；`boot_645/646» 2026-09-17 18:36/18:38 |
| 14 | **335** | **1699** | **50** | **3** | 0 | **3250** | 3250 | **3** | 备份 `oplusreserve2/3.img»；crux **2026-09-27 02:30:23** |
| 15 | 336 | 1699 | 50 | 3 | 0 | 3250 | 3250 | 未知 | 真机ext4/`merge_kernel_log» |
| 16 | 343 | 1758 | 51 | 3 | 0 | 3250 | 3250 | 未知 | 真机 `sdf6.bin» |
| 17 | **344** | **1758** | **51** | **3** | 0 | **3250** | **3250** | 未知 | 真机 `sdf6.bin» |
| 18 | **344** | **1758** | **51** | **3** | 340 | **3250** | **3350** | 未知 | 真机 `sdf6.bin» |
| 18b | 344 | 1758 | 51 | 3 | 340 | 3250 | **2600** | 未知 | 真机 `sdf6.bin» |
| 18c | **344** | **1758** | **51** | **3** | 344 | **3250** | **2540** | 未知 | 真机 `sdf4.bin»（模块 uv2800 生效） |

**注 1**：伪 “#18/18b/18c” 是同一组 (counts, cc, ratio, region) 下的不同 term_now，见 §4。
**注 2**：本清单**未**包含「只有 counts 没有 cc」或「只有 cc 没有 counts」的记录；那些一律归入“单侧数据”。

## 2. 每次值变化前后的成对样本（before / after）

### 2.1 3060 → 2800（#3 → #4）
| | counts | cc | ratio | region | count_cali | index_t | 值 |
|---|---|---|---|---|---|---|---|
| before #3 | 256 | 57 | 44 | **2** | 0 | 未知 | 3060 |
| after #4 | 763 | 172 | 44 | **2** | 0 | **2** | **2800** |

- **region 没变（2→2）** ⇒ region 不能解释
- cc 从 57 → 172（+115）⇒ k 有变化余地
- **有 crux 记录：2026-03-27 21:21:14 的 `temp_p@@2 / temp_n@@2» ⇒ index_t = 2**
- 结论：**2800 可以由 `表[2][2]» 这个格子直接给出，不需要引入 DT 改动。**

### 2.2 2800 → 3060（#4 → #5）—— 本批最关键的一对
| | counts | cc | ratio | region | count_cali | index_t | 值 |
|---|---|---|---|---|---|---|---|
| before #4 | **763** | **172** | 44 | **2** | 0 | **2** | **2800** |
| after #5 | **763** | **173** | 44 | **2** | 172 | **3** | **3060** |

- counts 完全相同（763）
- **region 完全相同（2→2）**
- cc 只动了 **+1**（172→173），count_cali 0→172
- **index_t 从 2 → 3**（两条 crux 分别打印 temp[2,2] 与 temp[3,3]，日期相隔 6.5 小时：2026-03-27 21:21:14 → 2026-03-28 03:50:38）
- 结论：**2800→3060 的变化由 index_t（温度档）单独解释**，与 region 无关。

> ⚠ **这直接推翻了我在第三批把 2800 归因为「社区 dtbo 改表」的读法。**
> 按代码级规则，`表[region=2][index_t=2] = 2800» 与 `表[region=2][index_t=3] = 3060» 是同一行相邻两格，
> **2800 是合法的原厂温度格，不需要 DT 被改动就能解释。**
> 这**不否认** AVB `dtbo_a» 公钥不匹配（那是独立、确实存在的证据），但**它失去了“2800 这个值”作为佐证**。
> 第三批 §6 里我写的“替代解释”现在应当升级为主解释。

### 2.3 3060 → 3150（#5 → #6）
| | counts | cc | ratio | region | count_cali | index_t | 值 |
|---|---|---|---|---|---|---|---|
| before #5 | 763 | 173 | 44 | **2** | 172 | **3** | 3060 |
| after #6 | 1159 | 224 | 51 | **3** | 222 | 未知 | **3150** |

- **region 变了：2 → 3**（ratio 44 → 51，跨过 50 边界，按 b.hs 归上档）
- cc 也变了（173 → 224，+51）⇒ k 也可能变
- index_t 对 #6 未知（那几条 recovery 日志没有 crux 行）
- 结论：**region 2→3 是首要触发因素**（也是唯一有确凿变化的桶）；**但不能排除 k 同时变化**，因为在 #2（cc=20, region=3）时 region 已经是 3 却仍给 3060 —— 说明 **region 单独不足以定值**。

### 2.4 3150 → 3250（#7 → #8）—— 第二次跳变
| | counts | cc | ratio | region | count_cali | index_t | 值 |
|---|---|---|---|---|---|---|---|
| before #7 | 1387 | 263 | 52 | **3** | 0 | 未知 | **3150** |
| after #8 | 1625 | 314 | 51 | **3** | 310 | **3** | **3250** |

- **region 完全没变（3 → 3）** ⇒ **region 不是触发因素**
- cc 变了 **+51**（263 → 314），count_cali 0 → 310 ⇒ **k 必然有变化**
- index_t 对 #7 未知、对 #8 = 3 ⇒ 不能排除 index_t 也变了
- 结论：**3150→3250 由 k（cc / count_cali 驱动）或 index_t 触发；与 region 无关。**
  在只凭日志可得的字段里，**k 是最可能的那一个**（cc 单调 +51），但要**最终定死必须给出 `row[i].f0» 与 `row[k].vbat1» 两张表**（RE-A / RE-C 应已有）。

### 2.5 汇总：两次跳变的触发因素（回答复核点 4）

| 跳变 | region | cc | index_t | 可解释因素 | 互斥排除 |
|---|---|---|---|---|---|
| **3060 → 3150**（#5→#6） | **2 → 3 变** | 173→224 变 | 未知 | **region 变化**（首要）；k 不能排除 | — |
| **3150 → 3250**（#7→#8） | **3 → 3 不变** | 263→314 变 | 未知→3 | **k（cc/count_cali）**；index_t 不能排除 | **region 被排除** |
| （附）2800 → 3060（#4→#5） | 2 → 2 不变 | 172→173 微变 | **2 → 3 变** | **index_t** | region / cc 被排除 |
| （附）3060 → 2800（#3→#4） | 2 → 2 不变 | 57→172 变 | 未知→2 | k 或 index_t | region 被排除 |

**所以“ratio 桶 2→3 触发 3060→3250”这个第二轮结论只对了一半的对**：
它只解释了 **3060→3150**；**3150→3250 与 region 无关**。整条 3060→3250 的抬升是
**region + k（+ 可能的 index_t）三者叠加**的结果，不是单一因素。

## 3. 哪些段是成对样本支撑的 / 哪些是单侧推测

### 3.1 成对样本支撑（可信）
| 结论 | 支撑样本 |
|---|---|
| ratio 字段 == floor(10·counts/cc) | 全部 18 条，零反例 |
| 3060 出现在 cc = 1 / 20 / 57 / 173（四个独立点，region 分别 0/3/2/2） | #1 #2 #3 #5 |
| **region 单独不足以定值**（region=3 时 cc=20 给 3060、cc=335 给 3250） | #2 vs #14 |
| 2800 与 3060 是 **同一 region(2)** 下 index_t 2 / 3 的相邻格 | #4 #5 + 两条 crux（有 temp） |
| 3150 出现在 region=3、cc=224/263 | #6 #7 |
| 3250 出现在 region=3、cc≥314 | #8–#18c |
| term_now 不由表决定（同 (counts,cc,region) 下出现 3250/3350/2540/2600 四种） | #17 #18 #18b #18c |

### 3.2 单侧 / 不可信（必须标注）
| 说法 | 状态 | 原因 |
|---|---|---|
| “3060 覆盖 counts 0~763、cc 57~172” | **作废** | 那是把 #3 与 #4/#5 并区间的无效读法；正确说法是「cc = 1/20/57/173 四个成对点」 |
| 2800 阶段的时间跨度（起点） | **单侧** | 只有 #4 一条成对样本带日期(2026-03-27)；起点只能由“cc 从 57 走到 172”夹出来 |
| 3150 阶段的区间（>2026-04-29） | **单侧** | #6/#7 的 recovery build 是 C.89(2026-04-29)，但**这两条本身没有日历时间戳** |
| 3150 样本的 index_t | **缺失** | 那几条 kernel log 没有 `temp_p/temp_n»（crux 行只在 DeepDischgInfo 上传时打印） |
| 早期三条 (#1 #2 #3) 的 index_t | **缺失** | 同上，且当时 DCS 还没生成 crux |
| 3050/3100/3200 等中间降档值的归属 | **单侧** | 只出现在四元组的第 3/4 位，没有独立成对样本 |
| `k» 的绝对值 | **无法计算** | 需要 `row[i].f0» 表与 `row[k].vbat1» 表（RE-A/RE-C），本批只有 `cc − count_cali» |

### 3.3 `count_cali» 的影响（尚未定论，标注为风险）
实测 `count_cali» 只有两种形态：**0**（#1#2#3#4#7#12#13#14#15#16#17#18）与 **≈ cc−0…4**（#5:172/173、#6:222/224、#8:310/314、#9#10#11:315/316-319、#18c:344/344）。
由于 `k = max{i : row[i].f0 − count_cali ≤ cc}» 里 count_cali 是**被减数**，
同一个 cc 在 cali=0 与 cali≈cc−3 时**会落到不同的 k**。
本批**无法**判定这会不会单独造成 3150→3250，**必须拿到 row 表才能算**。这是本批最大的未定量。

## 4. 附带确认：「3350 / 2540 不是表输出」

同一组 (counts=1758, cc=344, ratio=51, region=3, cali=0/340/344) 下：

| vterm_final（表输出） | term_now（电量计实持） | 场景 |
|---|---|---|
| 3250 | 3250 | 原厂 |
| 3250 | **3350** | 刷写后、无模块 |
| 3250 | **2600** | 模块（v10 目标 2800） |
| 3250 | **2540** | 模块（uv2800，target−260） |

⇒ **表输出 vterm_final 稳定为 3250；3350 / 2540 / 2600 都只出现在 term_now**。
⇒ 代码级确认用户的归类：**3350 与 2540 都不是 DDRC 表算出来的值**，而是电量计 IC 里被外部写入的值。
⇒ 也再次确认：**判档位必须用 vterm_final**（本批即如此），用 term_now 会被模块/解容污染。

## 5. 修正后的时间线（仅用成对样本）

```
#    cc  counts ratio region index_t  vterm_final  日期 / 依据
1     1       0     0      0      ?        3060     2025-10-26
2    20     136    68      3      ?        3060     2025-11-13
3    57     256    44      2      ?        3060     2025-12-13
4   172     763    44      2      2        2800     crux 2026-03-27 21:21:14   <- index_t=2 的格子
5   173     763    44      2      3        3060     crux 2026-03-28 03:50:38   <- index_t=3 的格子
6   224    1159    51      3      ?        3150     >2026-04-29 (recovery build C.89)
7   263    1387    52      3      ?        3150     同上
8   314    1625    51      3      3        3250     crux 2026-08-24 18:58:47
9-14 316..335 1625..1699 50-51 3 3        3250     2026-08-27 / 08-28 / 08-30 / 09-17 / 09-27
15-17 336..344 1699..1758 50-51 3   ?     3250     真机ext4 / 真机 sdf6
18  344    1758    51      3      ?        3250     真机 sdf4/sdf6（term_now 出现 3350/2600/2540）
```

区间的可信度分级：
- **cc 1 → 172 之间**：只有 #1#2#3 三个点（2025-10-26 / 2025-11-13 / 2025-12-13），中间无样本 ⇒ 只能说明“这三点都是 3060”，不能说明是连续的
- **cc 172 ↔ 173**：**两个相邻点，index_t 2↔3，值 2800↔3060** ⇒ 这是本批最结实的一对
- **cc 173 → 224**：跨度大（+51），中间无样本 ⇒ region 2→3 的“换档点”**只能定位在区间内**，无法定位到具体 cc
- **cc 263 → 314**：跨度 +51，中间无样本 ⇒ k 抬档点同样**只能定位在区间内**
- **cc 314 → 344**：点较密（314/316/317/319/327/329/335/336/343/344），值稳定 3250

## 6. 本批置信度

| 结论 | 置信度 | 依据 |
|---|---|---|
| ratio == floor(10·counts/cc) | **高** | 18/18 成对样本零反例 |
| 2800→3060 由 **index_t 2→3** 解释 | **高** | 两条带 temp 的 crux（同 region=2、同 counts=763，仅 6.5 h 之隔） |
| 「3060 覆盖 counts 0~763 / cc 57~172」作废 | **高** | 数据中不存在 (763,57)；该读法把两个样本并区间 |
| **3060→3150 由 region 2→3 触发** | **中高** | region 确有变化；但 #2 显示 region=3 也能给 3060 |
| **3150→3250 与 region 无关** | **高** | #7 与 #8 region 均为 3 |
| 3150→3250 由 **k（cc/count_cali）** 触发 | **中** | cc +51 是唯一单调变量；但 count_cali 的作用未定量，且 index_t 缺失 |
| 表输出 = vterm_final；3350/2540/2600 只出现在 term_now | **高** | 同 (counts,cc,region) 下 4 种 term_now |
| k 的绝对值 / 换档的具体 cc 阈值 | **无法确定** | 缺 `row[i].f0» 与 `row[k].vbat1» 表 |

## 7. 本批复现命令

```bash
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/c1.py   # 成对样本清单 + ratio 自洽校验
<HOME>/reverse/venv/bin/python3 /tmp/oxlogs2/c2.py   # 加入早期(merge_kernel_log)与真机样本 + region 代入
```



