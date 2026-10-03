# KernelSU「越狱模式」卸载模块后软重启，会不会删除模块文件夹？

> 源码级调研结论 · 供其他会话直接引用
> 调研对象：`tiann/KernelSU @ 08a3b087e49227c8a6731c5f1114998b5e25255b`（2026-09-24）、`KernelSU-Next @ 2b31f7185460e99bc3896a639e9073b1c354ee0d`
> 文档来源：kernelsu.org（仓库内 `website/docs/`）+ 上述 GitHub 仓库源码

---

## 0. 结论（先看这里）

**会删除。** 前提是：你点的是 KernelSU Manager 里的「**软重启**」按钮 —— 它实际执行的是 `ksud soft-reboot`，而不是内核层面的重启。

一句话原因：**ksud 的「软重启」是"模拟"出来的**。它在 `stop` 之后会显式重新调用一次 `on_post_data_fs()`，而 `on_post_data_fs()` 里就包含 `prune_modules()` → `remove_dir_all()`。所以「卸载（只写 `remove` 标记）+ 软重启」= 模块目录真的被递归删除。

**反直觉推论**：在越狱（late-load）模式下，「**完整重启**」反而**不会**删目录 —— 因为开机时 KSU 根本没加载，init 不会执行 `ksud post-fs-data`；`remove` 标记会一直留到**下一次越狱（`ksud late-load`）**时才被清除。

**关键区分**：Manager 重启菜单里同时存在「软重启」(`soft_reboot`) 和「用户空间重启」(`userspace`)，两者**不等价**。只有「软重启」走 ksud 的模拟 post-fs-data 并触发删除；「用户空间重启」走 `svc power reboot userspace`，越狱模式下不会删。

---

## 1. 卸载模块本身不删目录，只写一个 `remove` 标记

Manager 点「卸载」→ `KsuCli.kt` 的 `uninstallModule()`：

```kotlin
// manager/app/src/main/java/me/weishu/kernelsu/ui/util/KsuCli.kt:172-177
fun uninstallModule(id: String): Boolean {
    val cmd = "module uninstall $id"
    val result = execKsud(cmd, true)
    Log.i(TAG, "uninstall module $id result: $result")
    return result
}
```

ksud 分发（`userspace/ksud/src/cli.rs:532`）→ `module::uninstall_module`：

```rust
// userspace/ksud/src/module.rs:702-720
pub fn uninstall_module(id: &str) -> Result<()> {
    validate_module_id(id)?;

    let module_path = Path::new(defs::MODULE_DIR).join(id);
    ensure!(module_path.exists(), "Module {id} not found");

    // Mark for removal
    let remove_file = module_path.join(defs::REMOVE_FILE_NAME);
    File::create(remove_file).with_context(|| "Failed to create remove file")?;   // ← 只创建 remove 文件

    info!("Module {id} marked for removal");

    if let Err(e) = regenerate_preinit_rc() {
        warn!("regenerate preinit rc failed: {e}");
    }
    Ok(())
}
```

相关常量：
- `userspace/ksud/src/defs.rs:23` → `MODULE_DIR = "/data/adb/modules/"`
- `userspace/ksud/src/defs.rs:36` → `REMOVE_FILE_NAME = "remove"`

官方文档也写明（`website/docs/zh_CN/guide/module.md:69`）：

```
│   ├── remove              <--- 如果这个文件存在，下次重启的时候模块会被移除
```

**这一步没有任何删除动作。**

---

## 2. 唯一真正删除目录的地方是 `prune_modules()`

```rust
// userspace/ksud/src/module.rs:309-360
pub fn prune_modules() -> Result<()> {
    foreach_module(All, |module| {
        if !module.join(defs::REMOVE_FILE_NAME).exists() {
            return Ok(());                      // 没有 remove 标记 → 跳过
        }

        info!("remove module: {}", module.display());

        // Execute metamodule's metauninstall.sh first
        let module_id = module.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let is_metamodule = read_module_prop(module).is_ok_and(|props| metamodule::is_metamodule(&props));
        if is_metamodule {
            ... metamodule::remove_symlink() ...
        } else if let Err(e) = metamodule::exec_metauninstall_script(module_id) { ... }

        // Then execute module's own uninstall.sh
        let uninstaller = module.join("uninstall.sh");
        if uninstaller.exists() && let Err(e) = exec_script(uninstaller, true) { ... }

        // Clear module configs before removing module directory
        ... crate::module_config::clear_module_configs(module_id) ...

        // Finally remove the module directory
        if let Err(e) = remove_dir_all(module) {           // ★ 第 347 行：真正 rm -rf
            warn!("Failed to remove {}: {e}", module.display());
        }
        Ok(())
    })?;
    ...
}
```

- `remove_dir_all` 来自标准库：`userspace/ksud/src/module.rs:19`（`use std::fs::{... remove_dir_all ...}`）
- 遍历范围由 `foreach_module(All, ...)` 决定，只读 `defs::MODULE_DIR`（`module.rs:132-162`）

### `prune_modules()` 全仓库只有 3 个调用点

| 调用点 | 场景 |
|---|---|
| `userspace/ksud/src/init_event.rs:66` | `on_post_data_fs()` —— 标准开机的 post-fs-data 阶段 |
| `userspace/ksud/src/late_load.rs:89` | `ksud late-load` —— **越狱时** |
| `userspace/ksud/src/utils.rs:284` | `ksud uninstall` —— 彻底卸载 KernelSU |

---

## 3. Manager 的「软重启」= `ksud soft-reboot`

`RebootListPopup.kt:29-39` 注册重启项，其中 `reboot_soft` 的 reason 是 `"soft_reboot"`：

```kotlin
// manager/app/src/main/java/me/weishu/kernelsu/ui/component/rebootlistpopup/RebootListPopup.kt:29-39
return buildList {
    add(RebootListOption(R.string.reboot, ""))
    if (isRebootingUserspaceSupported) {
        add(RebootListOption(R.string.reboot_userspace, "userspace"))   // ← 注意这个
    }
    add(RebootListOption(R.string.reboot_soft, "soft_reboot"))          // ← 软重启
    add(RebootListOption(R.string.reboot_recovery, "recovery"))
    add(RebootListOption(R.string.reboot_bootloader, "bootloader"))
    add(RebootListOption(R.string.reboot_download, "download"))
    add(RebootListOption(R.string.reboot_edl, "edl"))
}
```

```kotlin
// manager/app/src/main/java/me/weishu/kernelsu/ui/util/KsuCli.kt:489-499
fun reboot(reason: String = "") {
    if (reason == "soft_reboot") {
        execKsud("soft-reboot", true, true)          // ★ 软重启 = 调 ksud，不是内核 reboot
        return
    }
    val shell = getRootShell()
    if (reason == "recovery") {
        ShellUtils.fastCmd(shell, "/system/bin/input keyevent 26")
    }
    ShellUtils.fastCmd(shell, "/system/bin/svc power reboot $reason || /system/bin/reboot $reason")
}
```

### 越狱模式下 Manager 强制走软重启

```kotlin
// manager/app/src/main/java/me/weishu/kernelsu/data/repository/SettingsRepositoryImpl.kt:24-27
/** Prefer soft reboot: always in jailbreak mode, or when the setting is enabled. */
fun isSoftRebootPreferred(): Boolean =
    Natives.isLateLoadMode || ksuApp.getSharedPreferences(SETTINGS_PREFS, Context.MODE_PRIVATE)
        .getBoolean(KEY_USE_SOFT_REBOOT, false)
```

卸载成功后的 snackbar 动作也据此选择（`ModuleMaterial.kt:255-264`），代码注释即开发者意图：

```kotlin
// manager/app/src/main/java/me/weishu/kernelsu/ui/screen/module/ModuleMaterial.kt:255-264
// Soft reboot keeps the jailbreak and still applies module changes
val softReboot = isSoftRebootPreferred()
...
    actionLabel = resource.getString(if (softReboot) R.string.reboot_soft else R.string.reboot),
...
    reboot(if (softReboot) "soft_reboot" else "")
```

---

## 4. `ksud soft-reboot` 会显式重跑 `on_post_data_fs()`

命令分发：`userspace/ksud/src/cli.rs:523` → `Commands::SoftReboot => crate::soft_reboot::soft_reboot()`

核心实现：

```rust
// userspace/ksud/src/soft_reboot.rs:152-219（节选）
pub fn soft_reboot() -> Result<()> {
    // check it avoid user click "soft_reboot" in manager when version mismatch
    if let Err(e) = ksucalls::ensure_uapi_version_matched() {
        error!("{e:#}, skip soft_reboot");
        return Ok(());
    }

    utils::daemonize_with(true, || -> Result<()> {     // 先自我 daemon 化，保证 stop 杀不掉自己
        switch_mnt_ns(1)?;                             // 切到全局 mount namespace，/data/adb/modules 才是真路径
        chdir("/")?;
        Ok(())
    })?;

    info!("emulating soft_reboot!");
    if let Err(e) = reset_boot_completed() { warn!("reset boot completed failed: {e}"); }
    run_stage("emulated-soft-reboot", true);

    ... Waitsys 收集服务 ...

    info!("stop");
    let status = Command::new("stop").status().context("stop failed")?;   // 停掉 Android 框架
    ...
    terminate_waitsys(&mut waitsys);

    info!("post-fs-data");
    on_post_data_fs()?;                              // ★ 第 204 行：手动重跑 post-fs-data
    info!("start");
    let status = Command::new("start").status().context("start failed")?; // 拉起框架
    info!("services");
    on_services();
    if let Err(e) = wait_for_boot_completed() { warn!("wait for boot completed failed: {e}"); }
    on_boot_completed();

    unsafe { _exit(0); }
}
```

而 `on_post_data_fs()` 内部（`userspace/ksud/src/init_event.rs:11-68`）：

```rust
pub fn on_post_data_fs() -> Result<()> {
    if let Err(e) = ksucalls::ensure_uapi_version_matched() { error!("{e:#}, skip on_post_fs_data"); return Ok(()); }
    ksucalls::report_post_fs_data();
    utils::umask(0);
    if let Err(e) = crate::module_config::clear_all_temp_configs() { warn!(...); }
    ...
    if utils::has_magisk() { warn!("Magisk detected, skip post-fs-data!"); return Ok(()); }   // ← 例外

    let safe_mode = crate::utils::is_safe_mode();
    ...
    assets::ensure_binaries(true).with_context(|| "Failed to extract bin assets")?;

    if safe_mode {
        warn!("safe mode, skip post-fs-data scripts and disable all modules!");
        if let Err(e) = crate::module::disable_all_modules() { warn!(...); }
        return Ok(());                                                                        // ← 例外：安全模式直接返回，不 prune
    }

    if let Err(e) = handle_updated_modules() { warn!("handle updated modules failed: {e}"); }  // 第 62 行
    if let Err(e) = prune_modules() { warn!("prune modules failed: {e}"); }                    // ★ 第 66 行
    ...
}
```

### 完整调用链

```
Manager「卸载」→ ksud module uninstall <id> → 写入 /data/adb/modules/<id>/remove（不删目录）
Manager「软重启」→ ksud soft-reboot
    → switch_mnt_ns(1) → stop
    → on_post_data_fs()
        → handle_updated_modules()      // modules_update → modules
        → prune_modules() → remove_dir_all(<id>)   ← 目录在这里被删
    → start → on_services() → on_boot_completed()
```

---

## 5. 内核侧完全不删任何东西

`kernel/` 下没有任何删除模块目录的逻辑。内核只做两件事：

1. 标准开机时注入 init rc（`kernel/runtime/ksud_integration.c:33-38`）：

```c
static const char KERNEL_SU_RC[] =
    "\n"
    "on post-fs-data\n"
    "    start logd\n"
    "    exec u:r:" KERNEL_SU_DOMAIN ":s0 root -- " KSUD_PATH " post-fs-data\n"
    ...
```

2. late-load 时**主动跳过**自己的 post-fs-data 处理（`kernel/supercall/dispatch.c:110-118`）：

```c
case EVENT_POST_FS_DATA: {
    static bool post_fs_data_lock = false;
    if (!post_fs_data_lock) {
        post_fs_data_lock = true;
        if (ksu_late_loaded) {
            pr_info("post-fs-data skipped (late load)\n");
        } else {
            pr_info("post-fs-data triggered\n");
            on_post_fs_data();
        }
    }
    break;
}
```

> 注意：这里跳过的只是**内核侧**初始化（白名单、`selinux_hide` 等，见 `kernel/runtime/boot_event.c:17-34`），与用户态 `prune_modules()` 无关。这正是"内核不删、ksud 删"的关键。

---

## 6. 反直觉推论：越狱模式下「完整重启」反而不删

官方文档 `website/docs/zh_CN/guide/module.md:437-500`（Late-load 模式差异表）明确：

| 行为 | 标准启动 | Late-load 模式 |
|------|:---:|:---:|
| 内核模块由 init (PID 1) 加载 | 是 | 否（启动后加载） |
| initrc 注入（模块 `.rc` 文件注入 init.rc） | 是 | **不可用** |
| ksud 的 kprobe 钩子 (execve/read/fstat/input) | 是 | 跳过 |
| 安全模式检测（音量键） | 是 | 始终禁用 |
| 启动日志抓取 (logcat/dmesg) | 是 | 跳过 |
| Magisk 共存检测 | 是 | 跳过 |
| `post-fs-data` 事件通知内核 | 是 | **跳过** |
| `post-fs-data.sh` / `post-fs-data.d/` 脚本 | 是 | 由 `late-load` 阶段替代 |

也就是说，越狱模式下开机时 KSU 没加载、rc 没注入，init 的 `on post-fs-data` 根本不会调 `ksud post-fs-data` → **不 prune**。

`remove` 标记会一直留着，直到**下一次越狱**时由 `userspace/ksud/src/late_load.rs:85-91` 处理：

```rust
if let Err(e) = handle_updated_modules() { warn!("handle updated modules failed: {e}"); }
if let Err(e) = prune_modules() { warn!("prune modules failed: {e}"); }     // ★ 第 89 行
```

**所以：软重启删、完整重启不删、下次越狱时才删。**

---

## 7. 软重启也**不删**的例外（`on_post_data_fs` 的提前返回）

`prune_modules()` 在 `init_event.rs:66`，之前任何一条提前返回都会导致不删：

| 位置 | 条件 | 行为 |
|---|---|---|
| `init_event.rs:12-15` | uapi 版本不匹配 | 直接 return |
| `init_event.rs:31-34` | `utils::has_magisk()` 检测到 Magisk | return（`utils.rs:221-223`） |
| `init_event.rs:36-60` | 安全模式 | 只 `disable_all_modules()` 后 return，**跳过 prune** |
| `init_event.rs:51` | `assets::ensure_binaries` 失败 | `?` 报错中断 |
| `soft_reboot.rs:154-157` | uapi 不匹配 | soft-reboot 整体跳过 |

安全模式判定（`userspace/ksud/src/utils.rs:152-166`）：

```rust
pub fn is_safe_mode() -> bool {
    let safemode = getprop("persist.sys.safemode").as_ref().is_some_and(|p| p == "1")
        || getprop("ro.sys.safemode").as_ref().is_some_and(|p| p == "1");
    ...
    ksucalls::check_kernel_safemode()
}
```

> 官方救砖文档（`website/docs/zh_CN/guide/rescue-from-bootloop.md`）也提示：安全模式下模块"被禁用但可卸载"，卸载后要真正删目录仍需满足上述条件。

---

## 8. 别和「用户空间重启」混淆

Manager 重启菜单里两项含义不同：

| 菜单项 | reason | 实际执行 | 越狱模式下会删目录吗 |
|---|---|---|---|
| 软重启 | `soft_reboot` | `ksud soft-reboot`（模拟 post-fs-data） | **会** |
| 用户空间重启 | `userspace` | `svc power reboot userspace`（Android 原生） | 不会（越狱模式无 rc 注入） |

---

## 9. KernelSU-Next 行为完全一致

- `next/userspace/ksud/src/soft_reboot.rs:152-219`：同样 `stop` → `on_post_data_fs()` → `start`
- `next/manager/.../ui/util/KsuCli.kt:401-403`：

```kotlin
fun reboot(reason: String = "") {
    if (reason == "soft-reboot") {
        // ksud (userspace)
        com.rifsxd.ksunext.ui.util.execKsud("soft-reboot", true, true)
        return
    }
    ...
}
```

- prune 调用点同构：`init_event.rs:66`、`late_load.rs:90`、`utils.rs:259`

---

## 10. 自验命令

```bash
git clone --depth 1 https://github.com/tiann/KernelSU.git
cd KernelSU

grep -rn "prune_modules" userspace/ksud/src/            # 只有 3 个调用点
sed -n '152,219p' userspace/ksud/src/soft_reboot.rs     # 看第 204 行 on_post_data_fs()
sed -n '11,68p'   userspace/ksud/src/init_event.rs      # 看第 66 行 prune_modules()
sed -n '702,720p' userspace/ksud/src/module.rs          # 看 uninstall 只写 remove
sed -n '309,360p' userspace/ksud/src/module.rs          # 看第 347 行 remove_dir_all
sed -n '110,118p' kernel/supercall/dispatch.c           # 看 late-load 跳过 post-fs-data
```

### 关键 GitHub 永久链接（commit `08a3b087e49227c8a6731c5f1114998b5e25255b`）

- soft_reboot.rs：https://github.com/tiann/KernelSU/blob/08a3b087e49227c8a6731c5f1114998b5e25255b/userspace/ksud/src/soft_reboot.rs#L152-L219
- init_event.rs：https://github.com/tiann/KernelSU/blob/08a3b087e49227c8a6731c5f1114998b5e25255b/userspace/ksud/src/init_event.rs#L11-L68
- module.rs（prune）：https://github.com/tiann/KernelSU/blob/08a3b087e49227c8a6731c5f1114998b5e25255b/userspace/ksud/src/module.rs#L309-L360
- module.rs（uninstall）：https://github.com/tiann/KernelSU/blob/08a3b087e49227c8a6731c5f1114998b5e25255b/userspace/ksud/src/module.rs#L702-L720
- dispatch.c：https://github.com/tiann/KernelSU/blob/08a3b087e49227c8a6731c5f1114998b5e25255b/kernel/supercall/dispatch.c#L110-L118
- 官方文档 Late-load 模式：https://kernelsu.org/zh_CN/guide/module.html#late-load-mode

---

## 11. 一句话总结

> 在越狱模式下卸载模块后，用 Manager 的「**软重启**」**会**删除模块文件夹 —— 因为「软重启」是 `ksud soft-reboot` 的模拟重启，它显式重跑了 `post-fs-data`（含 `prune_modules` → `remove_dir_all`）；而「完整重启」在越狱模式下反而不会删，要等下一次越狱（`ksud late-load`）才删。例外：安全模式 / 检测到 Magisk / uapi 不匹配时，`on_post_data_fs` 会提前返回，不删。
