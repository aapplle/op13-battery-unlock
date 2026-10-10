# 宿主回归

在仓库根目录运行，不需要 ADB 或手机：

```sh
python3 -m unittest discover -s 自动化测试矩阵/host -p 'test_*.py' -v
```

需要 Python 3、Bash、GCC 或 Clang。Windows 可使用 Git Bash 和 MinGW，编译器不在 PATH 时指定 `UV_HOST_CC` 为其可执行文件路径。文件和二进制均在临时目录生成；设备节点与 Android 命令由夹具替换。

- `test_kernel.py`：把实际 `内核源码/uv2800.c` 编译进 C 测试程序，用探针/厂商接口桩注入错误。覆盖逐个关键注册失败的逆序清理、部分初始化期间不改寄存器、未知 profile 关闭 ADSP、两代 setter ABI、错误传播、清除过期读数、任务级旁路隔离和进行中 I/O 遇到卸载时的地址生命周期。
- `test_scripts.py`：恢复脚本的成功/失败、陈旧记录、skip 状态和互斥行为；一键卸载的电压门槛、挂载残留、已有删除撤销、CLI 排删除失败，以及早启动兜底记录与实时验证的区分。
- `test_policy.py`：真实 AOSP Parcel 形式的 String16/boolean/null、多行偏移、异常退出 0、空/畸形响应、读回未变化、原键备份/迁移和共享 XML 保留。
- `test_tooling.py`：快照失败、续跑、单例前置状态以及构建制品校验。

宿主测试不验证 ARM64 指令、真实 Linux kprobe/CFI 行为或 ADSP 硬件。Windows 未具备 Linux flock 后端时，相应系统锁测试会显示跳过；上线前须在 Linux 运行完整宿主回归，并重新构建、执行真机矩阵。

构建前后可分别运行：

```sh
python3 自动化测试矩阵/host/build_metadata.py abi
bash 自动化测试矩阵/build.sh
python3 自动化测试矩阵/host/build_metadata.py verify
```

`abi` 只检查现有二进制的格式；`verify` 还要求构建清单与源码一致。缺清单或源码改动后未重新构建，校验应失败。
