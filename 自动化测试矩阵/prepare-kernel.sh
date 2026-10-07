#!/usr/bin/env bash
# Prepare the pinned kernel for an external module build without building vmlinux.
# KERNEL_DIR has the same meaning as in fetch-kernel.sh and build.sh.
set -euo pipefail

PREPARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_ROOT="$(cd "$PREPARE_DIR/.." && pwd)"

check_module_config() {
    local config="$1" setting
    # Preserve the settings that affect the module ABI, CFI and vendor reserves.
    # Tool version/capability updates from olddefconfig are kept in config.diff.
    for setting in \
        CONFIG_MODULES=y CONFIG_MODULE_UNLOAD=y CONFIG_MODVERSIONS=y \
        CONFIG_SMP=y CONFIG_PREEMPT=y CONFIG_ARM64_4K_PAGES=y \
        CONFIG_CFI_CLANG=y CONFIG_ANDROID_KABI_RESERVE=y \
        CONFIG_ANDROID_VENDOR_OEM_DATA=y CONFIG_DEBUG_INFO_BTF_MODULES=y \
        'CONFIG_LOCALVERSION="-4k"' CONFIG_LOCALVERSION_AUTO=y; do
        grep -Fxq "$setting" "$config" || {
            echo "✗ prepared config lost required setting: $setting" >&2
            return 1
        }
    done
}

prepare_kernel() {
    local kernel="${KERNEL_DIR:-$PREPARE_ROOT/编译用内核树}/android_kernel_oneplus_sm8750"
    local metadata="$PREPARE_DIR/host/build_metadata.py" compiler pin release tool
    [ -d "$kernel/.git" ] || { echo "✗ Run bash fetch-kernel.sh first: $kernel" >&2; return 2; }
    export PATH=/usr/lib/llvm-18/bin:$PATH
    for tool in make clang ld.lld llvm-ar python3 bc bison flex pkg-config pahole; do
        command -v "$tool" >/dev/null || { echo "✗ Missing build tool: $tool" >&2; return 2; }
    done
    compiler="$(clang --version | head -1)"
    [[ "$compiler" == *"clang version 18."* ]] || { echo "✗ LLVM 18 required: $compiler" >&2; return 2; }
    pin="$(python3 -c 'import runpy,sys; print(runpy.run_path(sys.argv[1])["KERNEL_COMMIT"])' "$metadata")"
    release="$(python3 -c 'import runpy,sys; print(runpy.run_path(sys.argv[1])["VERMAGIC"].split()[0])' "$metadata")"
    [ "$(git -C "$kernel" rev-parse HEAD)" = "$pin" ] || { echo "✗ Wrong kernel commit; expected $pin" >&2; return 1; }
    git -C "$kernel" diff --quiet HEAD -- || { echo "✗ Kernel tracked sources differ from pinned HEAD" >&2; return 1; }

    cp "$PREPARE_ROOT/编译前置/device_config" "$kernel/.config"
    make -C "$kernel" ARCH=arm64 LLVM=1 olddefconfig
    check_module_config "$kernel/.config"
    python3 "$kernel/scripts/diffconfig" "$PREPARE_ROOT/编译前置/device_config" "$kernel/.config" > "$kernel/config.diff"
    # The Android config names a generated whitelist absent from the source tree.
    # Populate it from the recorded exported symbols; never manufacture CRCs.
    if grep -Fxq 'CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"' "$kernel/.config" && [ ! -e "$kernel/abi_symbollist.raw" ]; then
        awk '{print $2}' "$PREPARE_ROOT/编译前置/Module.symvers" | LC_ALL=C sort -u > "$kernel/abi_symbollist.raw"
    fi
    make -C "$kernel" -j"${UV_JOBS:-$(nproc)}" ARCH=arm64 LLVM=1 modules_prepare
    cp "$PREPARE_ROOT/编译前置/Module.symvers" "$kernel/Module.symvers"
    [ "$(cat "$kernel/include/config/kernel.release")" = "$release" ] || {
        echo "✗ Prepared kernelrelease does not match $release" >&2
        return 1
    }
    cmp "$PREPARE_ROOT/编译前置/Module.symvers" "$kernel/Module.symvers"
    echo "Kernel ready: $release ($compiler)"
    echo "Config changes: $kernel/config.diff"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then prepare_kernel; fi
