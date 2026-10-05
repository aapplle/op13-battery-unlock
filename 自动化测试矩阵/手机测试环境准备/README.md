# 手机测试环境准备（双清 / 换 ROM / 换内核后必看）

> 双清会清掉 `/data` 与 `/sdcard`。这里放两样东西：
> ① 矩阵跑起来**依赖的手机文件**（越狱 CLI 与 profile）；② **越狱工具与各内核 profile**（ghostlock 不支持新内核时自己生成）。
>
> ⚠️ **GhostLock 的二进制与 APK 不随仓库分发**（上游 Apache-2.0）—— 用 [`fetch-ghostlock.sh`](fetch-ghostlock.sh) 按需拉取并校验官方 SHA256。

## 一、目录内容

| 路径 | 是什么 |
|---|---|
| `ghostlock-越狱工具/` | `tools/glk1_gen.py`（profile 生成器）、`tools/decode_glk1.py`、`profiles/`（各内核 GLK1）；**CLI / 提取器 / APK 不随仓库分发**，由 `fetch-ghostlock.sh` 按需拉取。详见 [其 README](ghostlock-越狱工具/README.md) |
| `设备文件/data/local/tmp/profile.bin` | 设备侧快照（**绑 6.6.30**；换内核后无效，见下） |
| `fetch-ghostlock.sh` | 从官方 release 下载 GhostLock 二进制/APK 并校验官方 SHA256 |
| `恢复到手机.sh` | 一键恢复：推送 CLI + **按设备 `uname -r` 自动挑 profile** + 校验（缺二进制时自动调 `fetch-ghostlock.sh`） |

## 二、为什么要有 profile 生成器

`profile.bin` 是 GLK1 文档，**绑内核 release**（里面是 `task_struct`/`cred` 字段偏移与内核符号偏移）。
官方 App 只内置有限几个内核 ⇒ **换 ROM/内核后 CLI 直接拒绝**：

```
[!] profile release mismatch: expected 6.6.66-…-4k, got 6.6.118-…-4k
```

`--force-attack` 也绕不过。本项目因此做了**不依赖 App** 的替代流程（官方提取器 + `glk1_gen.py`），
已在 ColorOS 15 / 6.6.66（官方未收录）上实测越狱成功。原理与踩过的坑见
[ghostlock-越狱工具/README.md](ghostlock-越狱工具/README.md)。

> ⚠️ **适用范围（重要）**：这套方法解决的是"**官方未收录该内核**"，**不是**"官方已封堵"。
> **C17（ColorOS 17 / 6.6.118）的越狱注入没有实测**；GhostLock 的注入方式在 C17 上不可用，
> 给 C17 生成 profile 也无法用本套流程越狱。矩阵里 C17 的 T4.1/T4.2 记为"未实测"的 SKIP
> （见 [兼容性总表](../兼容性总表.md) 的 C17 late-load 格：**⬜ 未实测**）。

## 三、用法

```sh
cd 自动化测试矩阵/手机测试环境准备
./fetch-ghostlock.sh             # 首次：拉取 GhostLock 官方二进制/APK（校验 SHA256）
./恢复到手机.sh --dry-run        # 先看要做什么（不碰设备）
./恢复到手机.sh                  # 恢复：自动挑本内核的 profile，推送并互算 md5 校验

# 本内核在 profiles/ 里没有现成档时 —— 现场生成（推荐）
UV_BOOTIMG=/path/to/boot.img ./恢复到手机.sh

# 或指定已有 profile（仍会校验 release 与设备是否一致）
UV_PROFILE=/path/to/x.bin ./恢复到手机.sh
```

脚本行为要点：
- **按设备 `uname -r` 自动选** `profiles/<uname -r>.bin`；选不到才退回设备侧快照并警告；
- 用 `decode_glk1.py` **校验 profile 的 release 与设备一致**，不一致直接中止（不浪费一次越狱）；
- 校验方式是**本地与设备互算 md5 比对** —— 不写死任何"期望 md5"（同一文件在多个地方写死过不同值，正是踩过的坑）；
- 生成出的新 profile 建议存回 `ghostlock-越狱工具/profiles/<uname -r>.bin`，下次就能直接命中。

## 四、`boot.img` 从哪来

- **本地已抽好的 6 份**：`<EXTERNAL>/厂商驱动与固件/boot_imgs/`（清单 `MANIFEST-boot_imgs.txt`，
  覆盖 6.6.30 / 6.6.66 / 6.6.89 / 6.6.118 各构建）；
- 必须选 **`uname -r` 完全一致**的那份（提取器/CLI 都按 release 校验）；
- ROM 整包已从工作区删除以腾空间（原始压缩包由作者保存在 NTFS D 盘），需要别的内核时从那取。

## 五、双清后的完整顺序

1. **刷 ROM / 双清** → 此时无 root；
2. 装 **KernelSU APK** → 用它 patch **当前 ROM 的**原厂 `init_boot.img` → fastboot 刷入；
   （⚠️ 不能用别的 ROM 版本打出来的 patch 镜像）
3. `su -c id` 确认 `uid=0`；
4. `./恢复到手机.sh`（本内核没有 profile 时加 `UV_BOOTIMG=...`）；
5. `cd 自动化测试矩阵 && ./run.sh` —— 自动安装被测模块、自动判定启动路线。

**前提**：KSU 管理器 APK 已安装并授权 —— ghostlock 注入时要取 APK 里的
`lib/arm64/libksud.so` 当 ksud（脚本会先用 `pm list packages` 检测，缺了会警告）。

## 六、校验（随时可重跑）

直接重跑脚本即可，它会打印**本地 ↔ 设备**的 md5 比对与 CLI 自检：

```sh
./恢复到手机.sh --dry-run   # 只看选择逻辑（不改设备）
./恢复到手机.sh             # 推送并校验
```

## 七、不需要备份的东西

| 曾经备份过、现已删除 | 为什么不需要 |
|---|---|
| `.ghostlock_iomem` | ghostlock 每次运行自己生成；且**绑内核版本**（换内核留旧的反而是隐患） |
| `.ghostlock_root.sh`、`.ghostlock_ksu.log` | 同样是它的运行时产物 |
| `/data/adb/ksud`、`/data/adb/uv2800_backup/`、模块目录 | KSU 开机自建 + `run.sh` 的 `ensure_module` 自动安装/重建 |
| `/data/local/tmp/uvtest/**` | `run.sh` 每次运行自动推送 |
| 刷机素材（KSU APK、原厂/patched `init_boot`、Zygisk/LSPosed、调试日志） | 按作者要求不保留 |

## 八、第三方与许可证

| 组件 | 来源 | 许可证 | 分发方式 |
|---|---|---|---|
| GhostLock（CLI / 提取器 / App） | [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app)，release `pre-release` = v1.2 (549)，commit `ff9991b` | **Apache-2.0** | **不随仓库分发**；`fetch-ghostlock.sh` 按需拉取并校验官方 SHA256 |
| `ghostlock-越狱工具/tools/glk1_gen.py`、`decode_glk1.py` | 本项目原创 | 随本仓库 | 随仓库分发 |
| `ghostlock-越狱工具/profiles/*.bin`、`*.conf` | 本项目生成/整理（部分基于官方 profile 包） | — | 随仓库（KB 级配置数据） |

完整声明（含上游自身的 3 个来源项目）见仓库根 [`THIRD-PARTY-NOTICES.md`](../../THIRD-PARTY-NOTICES.md)。
