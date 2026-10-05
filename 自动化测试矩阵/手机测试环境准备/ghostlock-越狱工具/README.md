# GhostLock 越狱工具 & 跨内核 profile 生成

> **位置**：`自动化测试矩阵/手机测试环境准备/ghostlock-越狱工具/`（矩阵的越狱环境套件之一）。
> 一键恢复（推送 CLI + 按设备内核自动挑 profile + 校验）用上一层的
> [`恢复到手机.sh`](../恢复到手机.sh)；它也会调用本目录的 `tools/decode_glk1.py` 做 release 校验。
> **新生成的 profile 请存成 `profiles/<uname -r>.bin`** —— 恢复脚本就是按这个命名自动命中的。
>
> ⚠️ **适用范围**：本套流程解决的是"**官方未收录该内核**"（已在 C15 / 6.6.66 实测越狱成功）。
> **C17（6.6.118）本套工具用不了** —— GhostLock 的注入方式在 C17 上不可用，生成 profile 也无法用本套流程越狱。

---

## 上游与许可证（重要）

本目录**不随仓库分发** GhostLock 的二进制与 APK —— 它们由上一层的
[`fetch-ghostlock.sh`](../fetch-ghostlock.sh) 从官方 release **按需下载**并比对官方 SHA256。

| 项 | 值 |
|---|---|
| 上游仓库 | [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) |
| 许可证 | **Apache-2.0** |
| 版本 | release `pre-release` = **v1.2 (549)** |
| commit | `ff9991b1c33b6e0d0faa60c48658410974b11791` |
| 上游自身的来源 | 其 README「Credits & License」列明基于 `NebuSec/CyberMeowfia`、`JoinChang/ghostlock-oneplus`、`x-spy/CVE-2026-43499-popsicle`（均 Apache-2.0） |

> 完整第三方声明见仓库根 [`THIRD-PARTY-NOTICES.md`](../../../THIRD-PARTY-NOTICES.md)。
> 本目录内的 `tools/*.py` 是**本项目原创**（不在上游 `tools/` 里），不适用上述许可证。

### 按需拉取

```sh
cd 自动化测试矩阵/手机测试环境准备
./fetch-ghostlock.sh                 # 下载 3 个资产并校验官方 SHA256
./fetch-ghostlock.sh --verify        # 只校验已存在的文件
./fetch-ghostlock.sh --with-profiles # 额外拉官方 kernel-profiles 包到 profiles-官方/
```

| 资产 | 官方 SHA256（前 8 位…后 4 位） |
|---|---|
| `ghostlock` | `4197e261…a95e` |
| `ghostlock-extract-linux-x86_64` | `650a0e06…3d3c` |
| `GhostLock-release.apk` | `0c7dd580…45cb` |

---

## 目录

| 文件 | 来源 | 说明 |
|---|---|---|
| `ghostlock` | **fetch 生成** | 越狱 CLI（240,696 B）—— `run.sh` 的 `JAILBREAK_CMD` 用的就是它 |
| `ghostlock-extract-linux-x86_64` | **fetch 生成** | **官方提取器**，从 `boot.img`/`payload.bin`/OTA URL 提取偏移 |
| `GhostLock-release.apk` | **fetch 生成** | 官方 App（2.4 MB）。**可导入 `.conf`**，不想用 CLI 时可走 App |
| `tools/glk1_gen.py` | 本项目原创 | `.conf` + 已知可用 GLK1 → **目标内核的 GLK1**（本项目的核心工具） |
| `tools/decode_glk1.py` | 本项目原创 | GLK1 解码器（校验/对比用） |
| `profiles/*.bin` | 本项目生成/整理 | 各内核的 GLK1；`.conf` 是提取器原始输出；`*.基准` 是已知可用的参照文档 |

---

## 为新内核生成 profile（3 步）

```sh
# ① 用官方提取器从【同版本内核的 boot.img】提取偏移（提取器会自己从镜像恢复 kallsyms，无需 root）
#    本地已抽好的 boot.img（覆盖 6.6.30/66/89/118 各构建，含清单）：
#      <EXTERNAL>/厂商驱动与固件/boot_imgs/
#    ROM 整包已从工作区删除腾空间，原始压缩包由作者保存在 NTFS D 盘
./ghostlock-extract-linux-x86_64 <boot.img> --format conf --out /tmp/new.conf
#    ⚠️ 必须选【uname -r 完全一致】的那份 boot.img（用 strings boot.img | grep '^6\.' 核对）

# ② 合并进已知可用的 GLK1（保留 6.x 族的调优参数与路由，只换 release + 符号偏移）
python3 tools/glk1_gen.py profiles/<已知可用>.bin /tmp/new.conf /tmp/profile.bin

# ③ 校验后存档 + 推送
python3 tools/decode_glk1.py /tmp/profile.bin          # 核对 release 与 offset 块
cp /tmp/profile.bin "profiles/$(adb shell uname -r | tr -d '\r').bin"   # 存档，下次自动命中
adb push /tmp/profile.bin /data/local/tmp/profile.bin
adb shell 'chmod 666 /data/local/tmp/profile.bin'
adb shell '/data/local/tmp/ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin'
```

> 更省事：直接 `UV_BOOTIMG=<boot.img> ../恢复到手机.sh` —— 它会跑完上面 ①②③ 并做本地/设备 md5 比对。

---

## ★ 实测得来的关键事实（2026-10-04，C15 / 6.6.66）

1. **`profile.bin` 绑内核 release，且 CLI 强制校验**：文件头就是 release 字符串（GLK1 头部第 16 字节起），
   与 `uname -r` 不符直接拒绝，`--force-attack` **不能**绕过。
2. **6.x 族里 `task_struct` / `cred` / 路由与 execution 调优是逐字节相同的**：
   仓库里 `6.6.30 → 6.6.127` 的 .conf 实测**只有 `offset{}` 块不同**（内核镜像符号偏移，随每次构建变）。
   → 所以「拿一份已知可用的 GLK1，只替换 release + offset 块」是安全的。
   本次 6.6.66 生成的 `task_struct` 15 个字段与 6.6.118 **完全相同**，只有 10 个符号偏移变了。
3. **`.ghostlock_iomem` 也绑内核**：文件头是 `# <uname -r>`，ghostlock 每次运行自己重建 —— 换内核别留旧的。
4. **提取器的 `kernel_phys_load`/`kernel_phys_offset` 在 PC 上跑是错的**（它读的是宿主 `/proc/iomem`，
   实测给出 x86 的 `0xFFFF0000`）。官方 6.6 profile **刻意省略**这两个字段，运行时按 SoC 公式回退
   （本机自动推出 `kernel_phys_load=0xa8000000`，正确）。→ `glk1_gen.py` **不写入**这两个字段。
5. **GLK1 v2 格式**（`ghostlock-app/src/core/profile/binary.h`，小端）：
   `u32 magic(0x0D000721) + u16 version(2) + u16 frontend + u16 backend + u16 middleware + u16 release_len`
   `+ 2B 对齐填充（头部固定 16 字节）+ release + u16 section_count`
   `+ 每节 { u8 name_len, name, u32 entry_count, 每项 u8 key_len, key, u64 value }`
   ⚠️ **`middleware` 字段同时编码路由选择**：`2 = select_stack`、`1 = tcp_zerocopy`、`3 = multicast_waiter`。
6. **越狱耗时**：正常约 15 s；首次（含 KernelSnitch 扫描）可能到 1~2 min。
   `run.sh` 的越狱超时已放宽到 150 s。

---

## 换 ROM 后的固定动作

```sh
# 0) 记录内核版本
adb shell uname -r
# 1) 找同版本的 boot.img（工作区 ROM 包 IMAGES/ 下），生成 profile（上面 3 步）
# 2) 推 ghostlock + profile 到 /data/local/tmp，注入
# 3) 越狱后进 KSU 管理器打开 shell 的 root 权限
# 4) cd 自动化测试矩阵 && ./run.sh
```
