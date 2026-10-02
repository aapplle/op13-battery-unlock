# 已废弃：v9~v13「SOC 显示层修正」路线（历史归档）

> 归档时间：2026-10-02 14:45
> 归档原因：**这条技术路线已被实测判死**，保留仅为追溯，**不要使用**。

## 为什么废弃

这一批模块试图在**显示层**修正 SOC（不动物量计本身），三个版本一路试错：

| 文件 | 当时的做法 | 结局 |
|---|---|---|
| `uv2800_v9.c/.ko` | v8 + `adsp_write`（只写电压不改强制状态）| ⚠️ `adsp_write` 有 bug：不设 bypass，被自己的 setter hook 强制成 2800，**写什么都是 2800** |
| `uv2800_v10.c/.ko` | + hook `bs_update_data+0x178/+0x1f8` 改输入 SOC | ⚠️ hook 生效（smooth_soc 23→62）但 **capacity 完全不变** |
| `uv2800_v11.c/.ko` | 改为在 kretprobe 里 `*(int *)buf = mapped` 写调用者缓冲区 | ❌ **越界写 → 设备崩溃重启** |
| `uv2800_v12.c/.ko` | 改 hook `chip_soc_show+0x20`（只改寄存器）| ⚠️ 只影响 sysfs 的 `chip_soc`，需 `mount --bind` 才能影响 Android，且会造成 6 点跳变 |
| `uv2800_v13.c/.ko` | 改 hook `oplus_gki_get_ui_soc`（kretprobe 改返回值）| ✅ 功能有效（capacity 29→34），**但高倍率放电误差 2~3 点且会跳变** |

## 判死依据（详见项目文档 §23.1）

1. **本质是显示层 hack**：只改「给 Android 看的那一个数字」，`battery_rm`/`chip_soc`/MMS item0 三方不一致；
2. **高倍率放电不准**：实测 8 路 CPU 满载 → 端电压跌落 **107mV**，内阻 **50~100mΩ**；
   外推 10W+（3DMark）跌落 **135~270mV** → SOC 误差 **1.5~3 个点**，且会「掉档再回弹」；
3. **电流保护形同虚设**：`soc_cur_max` 依赖的 MMS item 0x25 实测在 1A 负载下仍是 -22（陈旧值）。

## 正确路线（v9）

**直接写电量计的终止电压**（`deep_term_volt`，硬件寄存器 `0x800A`）+ 重启：

- 实测 term=2800 后电量计把满容量从 **4366 → 4956 mAh（+590mAh / +13.5%）**；
- **原生库仑计量**，与负载无关 → 高倍率下天然正确；
- 不需要任何显示层 hook，不需要 bind-mount。

→ 见项目文档 §23 / §24 / §25，以及 `_work/uv2800/uv2800_v9.c`（当前模块）。

## 仍然有用的部分（已提取到 v9）

- `uv_self_write`：修掉 `adsp_write` 的 bug（模块自己发起的 setter 调用放行）；
- `adsp_read`：直读 ADSP 原值（`oplus_fg_get_deep_term_volt` 是 `(dev, int *out)` 双参数）；
- `oplus_gki_get_ui_soc` 是 capacity 的真正来源（tracefs 实测 21 次/20s，而 `oplus_comm_set_ui_soc` 是 0 次）。
