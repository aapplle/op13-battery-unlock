#!/usr/bin/env python3
"""Bind a prebuilt module to its source and reject incompatible release artifacts."""
import argparse
import hashlib
import json
import runpy
import struct
import subprocess
import sys
from pathlib import Path

KERNEL_COMMIT = "6028f47faddaa27700f8dd3a1d83906ea8f27170"
VERMAGIC = "6.6.118-4k-g6028f47fadda SMP preempt mod_unload modversions aarch64"
SOURCES = ("内核源码/uv2800.c", "内核源码/Makefile")
INPUTS = SOURCES + ("编译前置/device_config", "编译前置/Module.symvers",
                    "自动化测试矩阵/host/kernel_dependencies.py")
MANIFEST = "模块源目录/uv2800.build.json"
dependencies = runpy.run_path(str(Path(__file__).with_name("kernel_dependencies.py")))


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_abi(module):
    data = Path(module).read_bytes()
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("module must be ELF64 little-endian")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    if header[1] != 1 or header[2] != 183:
        raise ValueError("module must be an AArch64 relocatable ELF")
    offset, entry_size, count, names_index = header[6], header[11], header[12], header[13]
    if entry_size != 64 or not count or names_index >= count or offset + count * 64 > len(data):
        raise ValueError("invalid ELF section table")
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, offset + i * entry_size)
                for i in range(count)]

    def content(section):
        start, size = section[4:6]
        if start + size > len(data):
            raise ValueError("ELF section exceeds file size")
        return data[start:start + size]

    strings = content(sections[names_index])
    by_name = {strings[s[0]:].split(b"\0", 1)[0]: s for s in sections}
    this_module = by_name.get(b".gnu.linkonce.this_module")
    if this_module is None or this_module[5] != 0x600:
        raise ValueError(".gnu.linkonce.this_module must be exactly 0x600 bytes")
    content(this_module)
    modinfo = by_name.get(b".modinfo")
    if modinfo is None:
        raise ValueError("missing .modinfo")
    values = [v[len(b"vermagic="):].decode("ascii").strip()
              for v in content(modinfo).split(b"\0") if v.startswith(b"vermagic=")]
    if values != [VERMAGIC]:
        raise ValueError(f"vermagic mismatch: {values!r}; expected {VERMAGIC!r}")
    return {"machine": "AArch64", "this_module_size": 0x600, "vermagic": VERMAGIC}


def check_bundle_text(root):
    module = Path(root) / "模块源目录"
    for path in module.rglob("*"):
        if path.is_file() and (path.suffix in (".sh", ".prop") or "META-INF" in path.parts):
            if b"\r\n" in path.read_bytes():
                raise ValueError(f"CRLF in package script/text: {path.relative_to(root)}; convert to LF")


def write_manifest(root, module, source_dir, kernel, compiler, output):
    root, kernel, source_dir = Path(root), Path(kernel), Path(source_dir)
    commit = subprocess.check_output(["git", "-C", str(kernel), "rev-parse", "HEAD"], text=True).strip()
    if commit != KERNEL_COMMIT:
        raise ValueError(f"kernel HEAD must be {KERNEL_COMMIT}, got {commit}")
    if subprocess.run(["git", "-C", str(kernel), "diff", "--quiet", "HEAD", "--"], check=False).returncode:
        raise ValueError("kernel tracked sources differ from pinned HEAD")
    if sha256(kernel / "Module.symvers") != sha256(root / "编译前置/Module.symvers"):
        raise ValueError("kernel Module.symvers differs from the committed ABI reference")
    # Hash the sources actually copied to the isolated build directory, then
    # compare them with the checkout before installing either artifact.
    inputs = {name: sha256(source_dir / Path(name).name) if name in SOURCES
              else sha256(root / name) for name in INPUTS}
    if any(inputs[name] != sha256(root / name) for name in INPUTS):
        raise ValueError("source changed during the build; rebuild before publishing")
    manifest = {
        "schema": 2,
        "inputs_sha256": inputs,
        "module_sha256": sha256(module),
        "abi": check_abi(module),
        "kernel": {"commit": commit, "config_sha256": sha256(kernel / ".config"),
                   "symvers_sha256": sha256(kernel / "Module.symvers")},
        "compiler": compiler,
        "vendor": dependencies["vendor_manifest"](kernel),
    }
    Path(output).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8", newline="\n")


def verify_manifest(root, module=None, manifest=None):
    root = Path(root)
    module = Path(module) if module else root / "模块源目录/uv2800.ko"
    manifest = Path(manifest) if manifest else root / MANIFEST
    if not manifest.is_file():
        raise ValueError("missing uv2800.build.json; rebuild using 自动化测试矩阵/build.sh before packaging")
    record = json.loads(manifest.read_text(encoding="utf-8"))
    if not isinstance(record, dict) or record.get("schema") != 2:
        raise ValueError("unsupported build manifest schema")
    expected = {name: sha256(root / name) for name in INPUTS}
    if record.get("inputs_sha256") != expected:
        raise ValueError("source/build inputs changed since uv2800.ko was built; rebuild required")
    if record.get("module_sha256") != sha256(module):
        raise ValueError("uv2800.ko hash differs from its build manifest")
    if record.get("kernel", {}).get("commit") != KERNEL_COMMIT:
        raise ValueError("build manifest kernel commit mismatch")
    vendor = record.get("vendor", {})
    if vendor.get("commit") != dependencies["VENDOR_COMMIT"] or vendor.get("repository") != dependencies["VENDOR_URL"]:
        raise ValueError("build manifest vendor dependency mismatch")
    if vendor.get("extra_links") != dependencies["EXTRA_LINKS"]:
        raise ValueError("build manifest vendor compatibility mapping mismatch")
    links = vendor.get("links", {})
    if not links or vendor.get("links_sha256") != hashlib.sha256(json.dumps(links, sort_keys=True).encode()).hexdigest():
        raise ValueError("build manifest vendor link mapping mismatch")
    if record.get("abi") != check_abi(module):
        raise ValueError("build manifest ABI mismatch")
    check_bundle_text(root)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("create", "verify", "abi"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--module", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--kernel", type=Path)
    parser.add_argument("--compiler")
    args = parser.parse_args()
    try:
        if args.command == "create":
            if not all((args.module, args.manifest, args.source_dir, args.kernel, args.compiler)):
                parser.error("create requires --module/--manifest/--source-dir/--kernel/--compiler")
            write_manifest(args.root, args.module, args.source_dir, args.kernel, args.compiler, args.manifest)
        elif args.command == "abi":
            print(json.dumps(check_abi(args.module or args.root / "模块源目录/uv2800.ko")))
        else:
            verify_manifest(args.root, args.module, args.manifest)
            print("Build manifest, source hashes, module ABI and package line endings: OK")
    except (OSError, ValueError, KeyError, TypeError, struct.error, subprocess.SubprocessError) as error:
        print(f"Build verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
