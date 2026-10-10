# 上游来源与第三方声明（THIRD-PARTY NOTICES）

> 本仓库主体（uv2800 内核模块及其脚本、测试矩阵、文档）以 **GPL-2.0** 发布（全文见 [`LICENSE`](LICENSE)）。
> 下列第三方组件各自保留其原有许可证，与 GPL-2.0 部分**分区**（独立文件 / 独立进程，属单纯聚合）。
> 本仓库**不随代码分发**任何第三方源码树或二进制 —— 需要时由脚本按需拉取并校验。

| 第三方组件 | 许可证 | 获取方式 | 随仓库分发 |
|---|---|---|---|
| Linux 内核源码树（编译用） | GPL-2.0 | [`fetch-kernel.sh`](fetch-kernel.sh) | ❌ 否（解压约 1.6 GB） |
| GhostLock 越狱工具（CLI / 提取器 / App） | **Apache-2.0** | [`自动化测试矩阵/手机测试环境准备/fetch-ghostlock.sh`](自动化测试矩阵/手机测试环境准备/fetch-ghostlock.sh) | ❌ 否（约 7 MB） |
| 本仓库自研部分（`uv2800.c`、模块脚本、测试矩阵、`tools/glk1_gen.py` 等） | GPL-2.0 | 本仓库 | ✅ 是 |

---

# 一、Linux 内核源码树 —— GPL-2.0

## 1.1 上游仓库（固定版本）

| 用途 | 仓库 | 分支 | 固定 commit |
|---|---|---|---|
| **编译模块（必需）** | [OnePlusOSS/android_kernel_oneplus_sm8750](https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750) | `oneplus/sm8750_b_16.0.0_oneplus_13` | `6028f47faddaa27700f8dd3a1d83906ea8f27170` |
| **OEM Kconfig/头文件依赖（编译必需，稀疏检出）**，其余厂商驱动与设备树供对照 | [OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750) | `oneplus/sm8750_b_16.0.0_oneplus_13` | `d50b305f7da9e14715a25120a4ac7b1a4b8b97c3` |

- **内核版本**：Linux 6.6.118
- **许可证**：GPL-2.0（树内 `COPYING`：`SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note`）
- **版权**：归 OnePlus / OPPO 及 Linux 内核贡献者所有；本仓库仅为构建时引用，不主张其版权

## 1.2 为什么不分发内核树

1. **无必要**：该内核树是 GPL-2.0，且一加官方已在 GitHub 公开发布同一版本；本仓库再分发只是重复镜像。
2. **体积不可行**：解压后约 1.6 GB。GitHub 硬限制为单文件 100 MB、单次 push 2 GB。
3. **业界惯例**：内核模块仓库只放模块源码 + 打包脚本，构建时按需拉取内核树（同类项目如 `serein-213/batt-design-override-module` 即"纯 out-of-tree，不污染源码树"）。

## 1.3 拉取

```sh
./fetch-kernel.sh
# 默认落到 ./编译用内核树/android_kernel_oneplus_sm8750
```

固定内核自带指向 OEM 树的相对符号链接，包括 `kernel/oplus_cpu`、`drivers/soc/oplus/dfr`、传感器、显示 trackpoint 及公开头文件；只拉内核会让 Kconfig 的 `source` 入口断开。`fetch-kernel.sh` 也会按固定提交稀疏检出这些链接实际引用的 OEM 子树，并建立 `编译用内核树/../vendor` 链接恢复上游布局。内核中的原始链接保持不变；不会生成空 Kconfig 或移除 ABI 配置。下载后递归检查 Kconfig 入口，构建清单记录 OEM commit 和链接映射摘要。

## 1.4 编译

```sh
export PATH=/usr/lib/llvm-18/bin:$PATH
ROOT="$PWD"
KT="$ROOT/编译用内核树/android_kernel_oneplus_sm8750"
KB="$ROOT/编译前置"

# 1) 用编译前置里的 device_config 配置内核树（首次需要）
cp "$KB/device_config" "$KT/.config"
cd "$KT"
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 modules_prepare
cp "$KB/Module.symvers" "$KT/Module.symvers"

# 2) 在隔离目录编译、校验 ABI、同步 .ko/构建清单，再打包
cd "$ROOT"
bash 自动化测试矩阵/build.sh
```

> 构建脚本生成 `模块源目录/uv2800.build.json`，记录实际源码、配置、符号表、工具链与二进制摘要。发布工作流要求清单匹配当前源码，禁止把旧 `.ko` 当作新源码制品直接打包。

**产物核验基线**：`.gnu.linkonce.this_module` 节区大小应严格为 `0x600`（1536 字节）。

---

# 二、GhostLock（越狱工具）—— Apache-2.0

| 项 | 值 |
|---|---|
| 名称 | GhostLock（GhostLock One-Tap Execution App，CVE-2026-43499） |
| 上游仓库 | https://github.com/YuKongA/ghostlock-app |
| 许可证 | **Apache License 2.0**（全文见 [`LICENSES/Apache-2.0.txt`](LICENSES/Apache-2.0.txt)） |
| 引用版本 | release `pre-release` = **v1.2 (549)**，commit `ff9991b1c33b6e0d0faa60c48658410974b11791` |
| 版权 | 归 YuKongA 及 GhostLock 贡献者所有 |

## 2.1 本仓库的分发方式：**不分发其二进制**

GhostLock 的 CLI、提取器与 Android App **不包含在本仓库中**。需要时由
[`自动化测试矩阵/手机测试环境准备/fetch-ghostlock.sh`](自动化测试矩阵/手机测试环境准备/fetch-ghostlock.sh)
从官方 release 下载，并**强制比对官方 SHA256**：

| 资产 | 官方 SHA256 |
|---|---|
| `ghostlock` | `4197e2618dbfe12f1614fdf6f933b5adec59a2e82dd3add5ec2306ddf494a95e` |
| `ghostlock-extract-linux-x86_64` | `650a0e065f679853bbd96b8973a0181c63a9ad6367fdb6593e55e8efd8bb3d3c` |
| `GhostLock-release.apk` | `0c7dd5801e172a74b0ae6808825aaf8bd00edbcadd30063ef9c380fc129845cb` |

> 因此 Apache-2.0 §4(a)/(b)/(c) 中"再分发"相关的义务不触发；本节署名仍按上游要求主动提供。
> 若你通过 `fetch-ghostlock.sh` 取得了这些文件，使用它们时**适用 Apache-2.0 条款**（含 §7 无担保、§6 不授予商标许可）。

## 2.2 上游自身的来源（其 README「Credits & License」）

GhostLock 声明其基于以下 **Apache-2.0** 项目：

- NebuSec/CyberMeowfia — https://github.com/NebuSec/CyberMeowfia
- JoinChang/ghostlock-oneplus — https://github.com/JoinChang/ghostlock-oneplus
- x-spy/CVE-2026-43499-popsicle — https://github.com/x-spy/CVE-2026-43499-popsicle

## 2.3 本仓库中属于本项目原创的部分（不受上述许可证约束）

- `自动化测试矩阵/手机测试环境准备/ghostlock-越狱工具/tools/glk1_gen.py`
- `自动化测试矩阵/手机测试环境准备/ghostlock-越狱工具/tools/decode_glk1.py`
- `.../profiles/*.bin`、`*.conf`（由上述工具生成/整理；GLK1 格式事实源自上游源码 `src/core/profile/binary.h`）

---

# 三、许可证兼容性说明

- 本仓库主体为 **GPL-2.0**。
- GhostLock 为 **Apache-2.0**：与 GPL-2.0-**only** 对"结合作品"不兼容（与 GPLv3 兼容）。
  本仓库通过**独立可执行文件 + adb 调用**的方式使用它，属单纯聚合，**不构成结合作品**。
  ⚠️ 请勿把 GhostLock 的代码链接/内嵌进本模块。
- 内核源码树为 **GPL-2.0**，与本仓库主体同族，无兼容性问题。

---

# 四、仓库目录一览

| 目录/文件 | 说明 |
|---|---|
| `模块源目录/` | 模块脚本（`service.sh`/`action.sh`/`log.sh` 等）与 `uv2800.ko` |
| `内核源码/` | 内核模块源码 `uv2800.c` + `Makefile`（唯一真源） |
| `编译前置/` | `device_config`、`Module.symvers`、`uvprobe` 探针模块 |
| `自动化测试矩阵/` | 回归矩阵唯一入口 `run.sh`、兼容性总表、`手机测试环境准备/`、`dt_inject/` |
| `逆向脚本与产物/` | 逆向分析报告（RE-A ~ RE-F） |
| `fetch-kernel.sh` | 拉取内核树（见 §一） |
| `LICENSE` | 本仓库主体许可证（GPL-2.0 全文） |
| `LICENSES/` | 第三方许可证全文（当前含 Apache-2.0） |
| `THIRD-PARTY-NOTICES.md` | 本文件 |
| `编译用内核树/` | **不在仓库内**，由 `fetch-kernel.sh` 生成 |

> `文档/`（README 与项目技术文档）正在撰写，完成后补入本仓库。
