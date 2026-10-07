#!/usr/bin/env python3
"""Restore the pinned kernel's original OEM symlinks using a sparse vendor checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

VENDOR_COMMIT = "d50b305f7da9e14715a25120a4ac7b1a4b8b97c3"
VENDOR_URL = "https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8750.git"
VENDOR_NAME = "android_kernel_modules_and_devicetree_oneplus_sm8750"


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args])


def vendor_target(kernel, link, target):
    """Return a vendor-repo path only for original links to the upstream vendor root."""
    kernel = Path(kernel).resolve()
    destination = Path(os.path.abspath(kernel / Path(link).parent / target))
    mount = kernel.parent.parent / "vendor"
    try:
        relative = destination.relative_to(mount)
    except ValueError:
        return None
    return (Path("vendor") / relative).as_posix()


def kernel_links(kernel):
    links = {}
    for entry in git(kernel, "ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        if metadata.split()[0] != b"120000":
            continue
        path = raw_path.decode()
        source = Path(kernel) / path
        if not source.is_symlink():
            raise ValueError(f"kernel checkout did not preserve symlink: {path}")
        destination = vendor_target(kernel, path, os.readlink(source))
        if destination:
            links[path] = destination
    if not links:
        raise ValueError("pinned kernel has no OEM symlinks; check the source checkout")
    return dict(sorted(links.items()))


def repository(kernel):
    return Path(kernel).resolve().parent / VENDOR_NAME


def ensure_mount(kernel, vendor):
    mount = Path(kernel).resolve().parent.parent / "vendor"
    expected = (Path(vendor) / "vendor").resolve()
    if mount.is_symlink():
        if mount.resolve() != expected:
            raise ValueError(f"existing vendor symlink points elsewhere: {mount}")
    elif mount.exists():
        raise ValueError(f"existing vendor path is not the generated symlink: {mount}")
    else:
        mount.symlink_to(expected, target_is_directory=True)


def check_kconfig_sources(kernel):
    """Check transitive source directives, including those under disabled if blocks."""
    kernel = Path(kernel).resolve()
    pending, visited, missing = [kernel / "Kconfig"], set(), []
    pattern = re.compile(r'^\s*source\s+["\']([^"\']+)["\']')
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        if not path.is_file():
            missing.append(str(path))
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            match = pattern.match(line)
            if not match:
                continue
            value = match[1].replace("$(SRCARCH)", "arm64").replace("$(KCONFIG_EXT_PREFIX)", "")
            value = value.replace("$(srctree)", str(kernel))
            if "$" in value:  # Remaining dynamic expressions are checked by Kconfig itself.
                continue
            source = kernel / value
            if source.is_file():
                pending.append(source)
            else:
                missing.append(f"{path.relative_to(kernel)}:{number}: {value}")
    if missing:
        raise ValueError("missing Kconfig sources:\n" + "\n".join(sorted(set(missing))))
    return len(visited)


def vendor_manifest(kernel):
    kernel = Path(kernel).resolve()
    vendor = repository(kernel)
    commit = git(vendor, "rev-parse", "HEAD").decode().strip()
    if commit != VENDOR_COMMIT:
        raise ValueError(f"vendor HEAD must be {VENDOR_COMMIT}, got {commit}")
    subprocess.run(["git", "-C", str(vendor), "diff", "--exit-code", "HEAD", "--"], check=True)
    mount = kernel.parent.parent / "vendor"
    if not mount.is_symlink() or mount.resolve() != (vendor / "vendor").resolve():
        raise ValueError("vendor mount no longer points to the pinned dependency checkout")
    links = kernel_links(kernel)
    broken = [name for name in links if not (kernel / name).exists()]
    if broken:
        raise ValueError("broken OEM links: " + ", ".join(broken))
    return {"repository": VENDOR_URL, "commit": commit, "links": links,
            "links_sha256": hashlib.sha256(json.dumps(links, sort_keys=True).encode()).hexdigest()}


def fetch(kernel):
    kernel = Path(kernel).resolve()
    vendor = repository(kernel)
    links = kernel_links(kernel)
    if not (vendor / ".git").is_dir():
        if vendor.exists() and any(vendor.iterdir()):
            raise ValueError(f"vendor checkout path is not an empty directory: {vendor}")
        vendor.mkdir(parents=True, exist_ok=True)
        git(vendor, "init")
        git(vendor, "remote", "add", "origin", VENDOR_URL)
    if git(vendor, "remote", "get-url", "origin").decode().strip() != VENDOR_URL:
        raise ValueError("vendor origin differs from the pinned upstream repository")
    git(vendor, "config", "remote.origin.promisor", "true")
    git(vendor, "config", "remote.origin.partialclonefilter", "blob:none")
    git(vendor, "fetch", "--depth", "1", "--filter=blob:none", "origin", VENDOR_COMMIT)
    targets = set(links.values())
    entries = git(vendor, "ls-tree", "-r", "-t", "-z", VENDOR_COMMIT, "--", *sorted(targets))
    types = {}
    for entry in entries.split(b"\0"):
        if entry:
            info, path = entry.split(b"\t", 1)
            if path.decode() in targets:
                types[path.decode()] = info.split()[1].decode()
    absent = sorted(set(links.values()) - set(types))
    if absent:
        raise ValueError("OEM symlink targets absent from pinned upstream: " + ", ".join(absent))
    sparse = sorted({path if kind == "tree" else str(Path(path).parent).replace("\\", "/")
                     for path, kind in types.items()})
    git(vendor, "sparse-checkout", "init", "--cone")
    git(vendor, "sparse-checkout", "set", "--cone", "--", *sparse)
    git(vendor, "checkout", "--detach", VENDOR_COMMIT)
    ensure_mount(kernel, vendor)
    record = vendor_manifest(kernel)
    count = check_kconfig_sources(kernel)
    (kernel / "vendor-dependencies.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(f"OEM dependency ready: {VENDOR_COMMIT}; {len(links)} original links; {count} Kconfig files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "verify"))
    parser.add_argument("--kernel", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "fetch":
            fetch(args.kernel)
        else:
            vendor_manifest(args.kernel)
            print(f"OEM dependency verified; {check_kconfig_sources(args.kernel)} Kconfig files")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"OEM dependency failure: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
