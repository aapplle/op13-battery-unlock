#!/usr/bin/env python3
"""Compile the actual kernel-module logic against host fault-injection stubs.

Requires GCC or Clang (UV_HOST_CC may specify the executable). This checks C
control flow, not ARM64 instructions, Linux ABI or the real ADSP driver.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


class KernelFaultTests(unittest.TestCase):
    def test_fault_injection(self):
        compiler = os.environ.get("UV_HOST_CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
        self.assertTrue(compiler, "Set UV_HOST_CC to a GCC/Clang executable")
        source = (ROOT / "内核源码/uv2800.c").read_text(encoding="utf-8")
        source = re.sub(r"^#include <linux/[^>]+>\s*$", "", source, flags=re.MULTILINE)
        harness = (HERE / "kernel_harness.c").read_text(encoding="utf-8")
        code = harness.replace("/* UV2800_SOURCE */", source)
        env = os.environ.copy()
        env["PATH"] = str(Path(compiler).resolve().parent) + os.pathsep + env.get("PATH", "")
        with tempfile.TemporaryDirectory(prefix="uv2800-kernel-") as temporary:
            temp = Path(temporary)
            unit = temp / "kernel_test.c"
            exe = temp / ("kernel_test.exe" if os.name == "nt" else "kernel_test")
            unit.write_text(code, encoding="utf-8", newline="\n")
            built = subprocess.run(
                [compiler, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-Wno-unused-parameter", "-Wno-unused-function", "-Wno-unused-variable",
                 "-Wno-sign-compare", "-Wno-attributes", str(unit), "-o", str(exe)],
                env=env, capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            print(ran.stdout, end="")


if __name__ == "__main__":
    unittest.main()
