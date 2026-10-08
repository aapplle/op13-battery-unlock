#!/usr/bin/env python3
"""Host regressions for test-runner isolation and release artifact checks.

No adb, phone, network, or kernel build is used. Run with unittest discovery.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


metadata = load_module("build_metadata")
resume = load_module("resume")
dependencies = load_module("kernel_dependencies")


def bash_path():
    configured = os.environ.get("UV_HOST_BASH") or shutil.which("bash")
    fallback = Path("C:/Program Files/Git/bin/bash.exe")
    return configured or (str(fallback) if fallback.exists() else None)


class RunnerTests(unittest.TestCase):
    def shell(self, body, *, source=True, extra_env=None):
        bash = bash_path()
        if not bash:
            self.skipTest("bash is required (set UV_HOST_BASH)")
        with tempfile.TemporaryDirectory(prefix="uv-tooling-") as directory:
            env = dict(os.environ, UV_OUT=Path(directory).as_posix(),
                       UV_RUN_SCRIPT=(ROOT / "自动化测试矩阵/run.sh").as_posix(),
                       UV_PREPARE_SCRIPT=(ROOT / "自动化测试矩阵/prepare-kernel.sh").as_posix(),
                       UV_FETCH_SCRIPT=(ROOT / "fetch-kernel.sh").as_posix(),
                       KERNEL_DIR=Path(directory).as_posix())
            for variable in ("UV_ROUTE", "UV_DT", "UV_SERIAL"):
                env.pop(variable, None)
            env.update(extra_env or {})
            script = ('. "$UV_RUN_SCRIPT"\n' if source else '') + body
            return subprocess.run([bash, "-s"], input=script, env=env,
                                  capture_output=True, encoding="utf-8", timeout=20)

    def assert_shell_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_snapshot_marks_case_failed_and_discards_old_values(self):
        result = self.shell('''
S=([ts]=old [vbat_uv]=2800 [param_resume]=0)
sh_dev() { return 1; }
t_T1_2
[ "$FAIL" = 1 ] && [ "$PASS" = 0 ] && [ "${#S[@]}" = 0 ]
''')
        self.assert_shell_ok(result)

    def test_failed_poll_cannot_match_stale_state(self):
        result = self.shell('''
S=([ts]=old [param_target]=2800)
sh_dev() { return 1; }
if wait_key param_target 2800 1; then exit 1; fi
[ "$CASE_FAILED" = 1 ] && [ "${#S[@]}" = 0 ]
''')
        self.assert_shell_ok(result)

    def test_route_failure_discards_route_but_preserves_device_identity(self):
        result = self.shell('''
DV=([boot_route]=standard [dev_model]=fixture [log_fresh]=yes)
ROUTE_KEYS=(boot_route log_fresh)
sh_dev() { return 1; }
if refresh_route; then exit 1; fi
[ "$ROUTE" = unknown ] && [ "${DV[boot_route]:-}" = "" ] &&
[ "${DV[log_fresh]:-}" = "" ] && [ "${DV[dev_model]}" = fixture ] && [ "$CASE_FAILED" = 1 ]
''')
        self.assert_shell_ok(result)

    def test_each_factory_case_sets_up_its_own_state(self):
        result = self.shell('''
snap() {
  S=([ts]=1 [adsp_orig]=3150 [param_resume]=0 [restore_target]=3330 [restore_pending]=no)
  if [ "$STATE" = factory ]; then
    S[skip]=yes; S[param_target]=3330; S[param_adsp]=3330; S[adsp_read]=3330
    S[adsp_state]=3330; S[vbat_uv]=3330; S[bind_layers]=0
  else
    S[skip]=no; S[param_target]=2800; S[adsp_read]=2540
    S[adsp_state]=2540; S[vbat_uv]=2800; S[bind_layers]=1
  fi
}
apply_dev() { [ "$1" = factory ] || return 1; STATE=factory; FACTORY_CALLS=$((FACTORY_CALLS+1)); }
for n in 1 2 3 4 5; do
  STATE=decouple; FACTORY_CALLS=0; PASS=0; FAIL=0; WANT=("T2.$n")
  run_case "T2.$n" "t_T2_$n"
  [ "$PASS" = 1 ] && [ "$FAIL" = 0 ] && [ "$FACTORY_CALLS" = 1 ] || exit 1
done
''')
        self.assert_shell_ok(result)

    def test_pending_restore_does_not_pass_even_when_action_returns_zero(self):
        result = self.shell('''
CALLS=0
snap() {
  S=([skip]=yes [restore_pending]=yes [restore_target]=3330 [param_target]=3330
     [param_adsp]=3330 [adsp_read]=3330 [adsp_state]=3330 [vbat_uv]=3330 [param_resume]=0 [bind_layers]=0)
}
apply_dev() { CALLS=$((CALLS+1)); return 0; }
snap
if ensure_factory; then exit 1; fi
[ "$CALLS" = 1 ] && [ "$CASE_FAILED" = 1 ]
''')
        self.assert_shell_ok(result)

    def test_failed_factory_action_cannot_reuse_previous_success(self):
        result = self.shell('''
S=([skip]=yes [restore_pending]=no [restore_target]=3330)
sh_dev() { return 37; }
apply_dev factory
rc=$?
[ "$rc" = 37 ] || exit 1
if ensure_factory; then exit 1; fi
[ "$CASE_FAILED" = 1 ]
''')
        self.assert_shell_ok(result)

    def test_reboot_cases_use_post_boot_restore_target(self):
        result = self.shell('''
snap() {
  S=([ts]=1 [adsp_orig]=3150 [restore_target]="$TARGET" [restore_pending]=no [skip]=yes
     [param_target]="$TARGET" [param_adsp]="$TARGET" [adsp_read]="$TARGET" [adsp_state]="$TARGET"
     [vbat_uv]="$TARGET" [param_resume]=0 [bind_layers]=0)
}
ensure_decouple() { return 0; }
apply_dev() { TARGET=3100; return 0; }
soft_reboot() { TARGET=3330; return 0; }
hard_reboot_jailbreak() { TARGET=3330; return 0; }
sh_dev() { return 0; }
for id in T3.2 T4.2 T5.1; do
  TARGET=3100; PASS=0; FAIL=0; WANT=("$id")
  "t_${id//./_}"
  [ "$PASS" = 1 ] && [ "$FAIL" = 0 ] && [ "${S[restore_target]}" = 3330 ] || exit 1
done
''')
        self.assert_shell_ok(result)

    def test_invalid_restore_target_does_not_pass_with_cleared_pending(self):
        result = self.shell('''
S=([skip]=yes [restore_pending]=no [restore_target]=2500 [param_target]=2500
   [param_adsp]=2500 [adsp_read]=2500 [adsp_state]=2500 [vbat_uv]=2500 [param_resume]=0 [bind_layers]=0)
if assert_factory_completed; then exit 1; fi
[ "$CASE_FAILED" = 1 ]
''')
        self.assert_shell_ok(result)

    def test_device_apply_propagates_action_and_service_exit_status(self):
        bash = bash_path()
        if not bash:
            self.skipTest("bash is required")
        with tempfile.TemporaryDirectory(prefix="uv-apply-") as directory:
            root = Path(directory)
            backup, module, logs = root / "backup", root / "module", root / "logs"
            for path in (backup, module, logs):
                path.mkdir()
            (module / "service.sh").write_text("exit 17\n", encoding="utf-8")
            (module / "action.sh").write_text("exit 23\n", encoding="utf-8")
            source = (ROOT / "自动化测试矩阵/dev/apply.sh").read_text(encoding="utf-8")
            source = source.replace("BK=/data/adb/uv2800_backup", f'BK="{backup.as_posix()}"')
            source = source.replace("M=/data/adb/modules/uv2800", f'M="{module.as_posix()}"')
            source = source.replace("/data/local/tmp/uvtest/last_service.log", f'"{(logs / "last_service.log").as_posix()}"')
            source = source.replace("/data/local/tmp/uvtest/last_action.log", f'"{(logs / "last_action.log").as_posix()}"')
            script = root / "apply.sh"
            script.write_text(source, encoding="utf-8", newline="\n")
            for operation, expected in (("factory", 23), ("decouple", 17), ("target", 17)):
                with self.subTest(operation=operation):
                    result = subprocess.run([bash, str(script), operation, "2800"],
                                            capture_output=True, encoding="utf-8", timeout=10)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertIn(f"rc={expected}", result.stdout)

    def test_fetch_failure_does_not_report_ready(self):
        result = self.shell('''
git() {
  case "$*" in *cat-file*|*fetch*) return 1 ;; *) return 0 ;; esac
}
. "$UV_FETCH_SCRIPT"
''', source=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("已就绪", result.stdout)

    def test_fetch_rejects_wrong_head_even_if_checkout_claims_success(self):
        result = self.shell('''
git() {
  case "$*" in *rev-parse*) echo wrong-head ;; *) return 0 ;; esac
}
. "$UV_FETCH_SCRIPT"
''', source=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("已就绪", result.stdout)

    def prepare_fixture(self, *, drop_setting=False):
        return self.shell(r'''
. "$UV_PREPARE_SCRIPT"
kernel="$KERNEL_DIR/android_kernel_oneplus_sm8750"
mkdir -p "$kernel/.git"
clang() { echo 'Ubuntu clang version 18.1.3'; }
ld.lld() { :; }
llvm-ar() { :; }
bc() { :; }
bison() { :; }
flex() { :; }
pkg-config() { :; }
pahole() { :; }
python3() {
  case "$*" in
    *KERNEL_COMMIT*) echo "$EXPECTED_PIN" ;;
    *VERMAGIC*) echo "$EXPECTED_RELEASE" ;;
    *) : ;;
  esac
}
git() { case "$*" in *rev-parse*) echo "$EXPECTED_PIN" ;; *) : ;; esac; }
make() {
  case "$*" in
    *olddefconfig*)
      if [ "$DROP_SETTING" = 1 ]; then sed -i '/^CONFIG_MODVERSIONS=/d' "$kernel/.config"; fi ;;
    *modules_prepare*)
      echo PREPARE_INVOKED
      mkdir -p "$kernel/include/config"
      echo "$EXPECTED_RELEASE" > "$kernel/include/config/kernel.release" ;;
  esac
}
prepare_kernel
cmp "$PREPARE_ROOT/编译前置/Module.symvers" "$kernel/Module.symvers"
grep -q '^module_layout$' "$kernel/abi_symbollist.raw"
''', source=False, extra_env={
            "EXPECTED_PIN": metadata.KERNEL_COMMIT,
            "EXPECTED_RELEASE": metadata.VERMAGIC.split()[0],
            "DROP_SETTING": "1" if drop_setting else "0", "UV_JOBS": "1",
        })

    def test_kernel_preparation_preserves_symbol_crcs_and_release(self):
        result = self.prepare_fixture()
        self.assert_shell_ok(result)
        self.assertIn("Kernel ready:", result.stdout)

    def test_olddefconfig_abi_change_stops_before_modules_prepare(self):
        result = self.prepare_fixture(drop_setting=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFIG_MODVERSIONS=y", result.stderr)
        self.assertNotIn("PREPARE_INVOKED", result.stdout)


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uv-resume-")
        self.addCleanup(self.temp.cleanup)
        self.results = Path(self.temp.name)
        self.current = self.results / "current"
        self.current.mkdir()
        self.identity = dict(zip(resume.FIELDS, (
            "device-a", "model-a", "rom-a", "kernel-a", "driver-hash", "standard",
            "zip-hash", "runner-hash", "3060", "1", "0")))
        self.report = dict(self.identity, asserts=[
            {"case": "T1.1", "result": "PASS"},
            {"case": "T1.2", "result": "FAIL"},
        ])

    def save(self, name="previous", **changes):
        directory = self.results / name
        directory.mkdir(exist_ok=True)
        path = directory / "report.json"
        path.write_text(json.dumps(dict(self.report, **changes)), encoding="utf-8")
        return path

    def test_current_directory_is_ignored(self):
        self.save()
        self.save("current", device="other-device")
        self.assertEqual(resume.resume_ids(self.results, self.current, self.identity), ["T1.1"])

    def test_environment_or_build_change_requires_rerun(self):
        for field in resume.FIELDS:
            with self.subTest(field=field):
                self.save(**{field: "changed"})
                self.assertEqual(resume.resume_ids(self.results, self.current, self.identity), [])

    def test_incomplete_legacy_report_is_not_reused(self):
        path = self.save()
        path.write_text('{"asserts":[{"case":"T1.1","result":"PASS"}]}', encoding="utf-8")
        self.assertEqual(resume.resume_ids(self.results, self.current, self.identity), [])

    def test_latest_different_environment_does_not_fall_back_to_older_match(self):
        old = self.save("older")
        os.utime(old, (1000, 1000))
        self.save("newer", device_rom="changed")
        self.assertEqual(resume.resume_ids(self.results, self.current, self.identity), [])

    def test_any_failed_assertion_prevents_case_reuse(self):
        self.save(asserts=[{"case": "T1.1", "result": "PASS"},
                           {"case": "T1.1", "result": "FAIL"}])
        self.assertEqual(resume.resume_ids(self.results, self.current, self.identity), [])


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uv-artifact-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in metadata.INPUTS + ("模块源目录/uv2800.ko",):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.module = self.root / "模块源目录/uv2800.ko"
        self.manifest = self.root / metadata.MANIFEST

    def create_manifest(self):
        kernel = self.root / "kernel"
        kernel.mkdir()
        (kernel / ".config").write_text("CONFIG_MODULES=y\n", encoding="utf-8")
        shutil.copyfile(self.root / "编译前置/Module.symvers", kernel / "Module.symvers")
        links = {"kernel/oplus_cpu": "vendor/oplus/kernel/cpu"}
        vendor = {"repository": dependencies.VENDOR_URL, "commit": dependencies.VENDOR_COMMIT,
                  "extra_links": dependencies.EXTRA_LINKS,
                  "links": links, "links_sha256": metadata.hashlib.sha256(json.dumps(links, sort_keys=True).encode()).hexdigest()}
        with mock.patch.object(metadata.subprocess, "check_output", return_value=metadata.KERNEL_COMMIT), \
             mock.patch.object(metadata.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
             mock.patch.dict(metadata.dependencies, {"vendor_manifest": lambda kernel: vendor}):
            metadata.write_manifest(self.root, self.module, self.root / "内核源码",
                                    kernel, "fixture compiler", self.manifest)

    def test_manifest_binds_sources_and_binary(self):
        self.create_manifest()
        metadata.verify_manifest(self.root)
        source = self.root / metadata.SOURCES[0]
        source.write_bytes(source.read_bytes() + b"\n/* changed */\n")
        with self.assertRaisesRegex(ValueError, "inputs changed"):
            metadata.verify_manifest(self.root)

    def test_changed_binary_is_rejected(self):
        self.create_manifest()
        self.module.write_bytes(self.module.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "hash differs"):
            metadata.verify_manifest(self.root)

    def test_unproven_existing_binary_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing uv2800.build.json"):
            metadata.verify_manifest(self.root)

    def test_wrong_abi_and_vermagic_are_rejected(self):
        original = self.module.read_bytes()
        mutations = []
        wrong_arch = bytearray(original)
        struct.pack_into("<H", wrong_arch, 18, 62)
        mutations.append(wrong_arch)
        mutations.append(original.replace(b"vermagic=6.6.118", b"vermagic=6.6.119"))
        header = struct.unpack_from("<16sHHIQQQIHHHHHH", original)
        wrong_size = bytearray(original)
        sections = [struct.unpack_from("<IIQQQQIIQQ", original, header[6] + i * 64)
                    for i in range(header[12])]
        names = sections[header[13]]
        strings = original[names[4]:names[4] + names[5]]
        for i, section in enumerate(sections):
            if strings[section[0]:].split(b"\0", 1)[0] == b".gnu.linkonce.this_module":
                struct.pack_into("<Q", wrong_size, header[6] + i * 64 + 32, 0x500)
        mutations.append(wrong_size)
        for mutated in mutations:
            with self.subTest(mutation=mutations.index(mutated)):
                self.module.write_bytes(mutated)
                with self.assertRaises(ValueError):
                    metadata.check_abi(self.module)

    def test_crlf_device_script_blocks_packaging(self):
        self.create_manifest()
        (self.root / "模块源目录/service.sh").write_bytes(b"#!/system/bin/sh\r\necho test\r\n")
        with self.assertRaisesRegex(ValueError, "CRLF"):
            metadata.verify_manifest(self.root)

    def test_changed_vendor_revision_is_rejected(self):
        self.create_manifest()
        record = json.loads(self.manifest.read_text(encoding="utf-8"))
        record["vendor"]["commit"] = "0" * 40
        self.manifest.write_text(json.dumps(record), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "vendor dependency mismatch"):
            metadata.verify_manifest(self.root)


class DependencyTests(unittest.TestCase):
    def test_storage_alias_reaches_real_sibling_without_replacing_storage(self):
        with tempfile.TemporaryDirectory(prefix="uv-storage-") as directory:
            root = Path(directory)
            kernel, vendor = root / "kernel", root / "vendor-repository"
            original = vendor / "vendor/oplus/kernel/storage/storage_feature_in_module"
            expected = vendor / "vendor/oplus/kernel/storage/common/io_metrics"
            (original / "common").mkdir(parents=True)
            expected.mkdir(parents=True)
            (expected / "Kconfig").write_text('config OPLUS_FEATURE_STORAGE_IO_METRICS\n  tristate "metrics"\n', encoding="utf-8")
            storage = kernel / "drivers/soc/oplus/storage"
            storage.parent.mkdir(parents=True)
            try:
                storage.symlink_to(original, target_is_directory=True)
            except OSError as error:
                if getattr(error, "winerror", None) == 1314:
                    self.skipTest("Windows symlink privilege is unavailable")
                raise
            original_link = os.readlink(storage)
            dependencies.ensure_extra_links(kernel, vendor)
            dependencies.ensure_extra_links(kernel, vendor)
            self.assertEqual(os.readlink(storage), original_link)
            self.assertEqual((storage / "common/io_metrics").resolve(), expected.resolve())
            self.assertEqual((storage / "common/io_metrics/Kconfig").read_bytes(), (expected / "Kconfig").read_bytes())

    def test_original_oem_link_layout_is_preserved(self):
        kernel = ROOT / "编译用内核树" / "android_kernel_oneplus_sm8750"
        self.assertEqual(dependencies.vendor_target(kernel, "kernel/oplus_cpu", "../../../vendor/oplus/kernel/cpu"),
                         "vendor/oplus/kernel/cpu")
        self.assertEqual(dependencies.vendor_target(kernel, "drivers/soc/oplus/trackpoint",
                         "../../../../../vendor/qcom/opensource/display-drivers/oplus/common/trackpoint"),
                         "vendor/qcom/opensource/display-drivers/oplus/common/trackpoint")
        self.assertIsNone(dependencies.vendor_target(kernel, "kernel/sched/walt/oem_sched", "../../oplus_cpu/misc/sched_assist"))

    def test_kconfig_preflight_reports_all_missing_sources(self):
        with tempfile.TemporaryDirectory(prefix="uv-kconfig-") as directory:
            kernel = Path(directory)
            (kernel / "Kconfig").write_text('source "first/Kconfig"\nif DISABLED\nsource "second/Kconfig"\nendif\n', encoding="utf-8")
            with self.assertRaises(ValueError) as error:
                dependencies.check_kconfig_sources(kernel)
            self.assertIn("first/Kconfig", str(error.exception))
            self.assertIn("second/Kconfig", str(error.exception))

    def test_kconfig_preflight_follows_transitive_oem_source(self):
        with tempfile.TemporaryDirectory(prefix="uv-kconfig-") as directory:
            kernel = Path(directory)
            cpu = kernel / "kernel/oplus_cpu"
            cpu.mkdir(parents=True)
            (kernel / "Kconfig").write_text('source "$(KCONFIG_EXT_PREFIX)kernel/oplus_cpu/Kconfig"\n', encoding="utf-8")
            (cpu / "Kconfig").write_text('source "kernel/oplus_cpu/child"\n', encoding="utf-8")
            (cpu / "child").write_text('config OPLUS_FEATURE_CPU\n  bool "CPU"\n', encoding="utf-8")
            self.assertEqual(dependencies.check_kconfig_sources(kernel), 3)


if __name__ == "__main__":
    unittest.main()
