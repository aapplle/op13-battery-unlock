#!/usr/bin/env python3
"""Isolated shell regressions. No adb, phone, mount, or real /sys access.

Run: python 自动化测试矩阵/host/test_scripts.py
Linux additionally exercises real flock serialization and process-exit release.
Windows Git Bash exercises control flow; real flock cases are explicitly skipped.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "模块源目录"
BASH = shutil.which("bash")
if not BASH and Path("C:/Program Files/Git/bin/bash.exe").exists():
    BASH = "C:/Program Files/Git/bin/bash.exe"


def shell(code, **kwargs):
    return subprocess.run([BASH, "-c", code], text=True, encoding="utf-8",
                          capture_output=True, timeout=20, **kwargs)


HAS_FLOCK = bool(BASH) and shell("command -v flock").returncode == 0


@unittest.skipUnless(BASH, "bash is required (Git Bash supported)")
class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="uv2800-shell-test-"))
        self.addCleanup(self.cleanup)
        self.bk = self.root / "data/adb/uv2800_backup"
        self.params = self.root / "sys/module/uv2800/parameters"
        for path in (self.bk, self.params, self.root / "data/system",
                     self.root / "proc/1", self.root / "proc/self",
                     self.root / "sys/class/power_supply/battery",
                     self.root / "sys/class/oplus_chg/battery"):
            path.mkdir(parents=True, exist_ok=True)
        self.put("data/adb/uv2800_backup/adsp_orig.txt", "3250")
        for name, value in {"adsp_write": "not-written", "adsp_read": "0",
                            "uv_target_mv": "2800", "uv_adsp_mv": "2540",
                            "resume": "0"}.items():
            (self.params / name).write_text(value)
        self.put("sys/class/oplus_chg/battery/vbat_uv", "2800")
        self.put("sys/class/power_supply/battery/voltage_now", "3800000")
        self.put("hardware_voltage", "2540")
        for pid in ("1", "self"):
            self.put("proc/" + pid + "/mountinfo", "1 0 0:1 / / rw - rootfs rootfs rw\n")
        for original in SCRIPTS.glob("*.sh"):
            source = original.read_text(encoding="utf-8")
            for absolute in ("/sys/", "/data/", "/proc/"):
                source = source.replace(absolute, self.root.as_posix() + absolute)
            (self.root / original.name).write_text(source, encoding="utf-8", newline="\n")
        # Emulate only Android commands/sysfs callbacks, retaining production control flow.
        with (self.root / "log.sh").open("a", encoding="utf-8", newline="\n") as output:
            output.write(r'''
uv_log() { echo "LOG $*"; }
uv_log_sep() { :; }
uv_capture_dev() { :; }
uv_dt_orig() { [ "$FAKE_MODE" = dt_error ] && return 1; echo "${FAKE_DT:-3250}"; }
uv_find_ksud() { [ -n "$FAKE_KSUD" ] && echo "$FAKE_KSUD"; }
uv_unbind_capacity() { return 0; }
lsmod() { echo "uv2800 100 0"; }
sleep() { :; }
su() {
    [ "$FAKE_MODE" = policy_error ] && return 1
    case "$*" in
        *"oplusdevicepolicy 4 "*)
            case "$FAKE_MODE" in
                policy_get_exception) echo 'Result: Parcel(ffffffff 00000000)'; return 0 ;;
                policy_empty) return 0 ;;
            esac
            _fake_policy=$(command cat "$FAKE_ROOT/policy" 2>/dev/null)
            case "$_fake_policy" in
                true) echo 'Result: Parcel(00000000 00000004 00720074 00650075 00000000)' ;;
                false) echo 'Result: Parcel(00000000 00000005 00610066 0073006c 00000065)' ;;
                *) echo 'Result: Parcel(00000000 ffffffff)' ;;
            esac ;;
        *"oplusdevicepolicy 1 "*)
            echo setter >> "$FAKE_ROOT/policy_events"
            [ "$FAKE_MODE" = policy_set_exception ] && { echo 'Result: Parcel(ffffffff 00000000)'; return 0; }
            if [ "$FAKE_MODE" != policy_unchanged ]; then
                case "$*" in
                    *"s16 true"*) echo true > "$FAKE_ROOT/policy" ;;
                    *"s16 false"*) echo false > "$FAKE_ROOT/policy" ;;
                esac
            fi
            echo 'Result: Parcel(00000000 00000001)' ;;
        *) return 1 ;;
    esac
}
cat() {
    case "$1" in
        */parameters/adsp_read)
            echo read >> "$FAKE_ROOT/read_events"
            [ "$FAKE_MODE" = read_error ] && return 1
            if [ "$FAKE_MODE" = mismatch ]; then
                command cat "$FAKE_ROOT/hardware_voltage"
            else
                _fake_v=$(command cat "$FAKE_ROOT/sys/module/uv2800/parameters/adsp_write" 2>/dev/null)
                case "$_fake_v" in ''|*[!0-9]*) command cat "$FAKE_ROOT/hardware_voltage" ;; *) echo "$_fake_v" ;; esac
            fi ;;
        */parameters/resume) echo 0 ;;
        */battery/vbat_uv) command cat "$FAKE_ROOT/sys/module/uv2800/parameters/uv_target_mv" ;;
        *) command cat "$@" ;;
    esac
}
''')
            if not HAS_FLOCK:
                output.write("\nuv_lock() { return 0; } # Host lacks flock; separate tests cover selection.\n")

    def cleanup(self):
        target = self.root.resolve()
        if not target.is_relative_to(Path(tempfile.gettempdir()).resolve()):
            raise RuntimeError("fixture cleanup escaped temporary directory")
        shutil.rmtree(target)

    def put(self, name, value):
        (self.root / name).write_text(value, encoding="utf-8")

    def run_script(self, name="action.sh", mode="success", args=(), **extra):
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix(), FAKE_MODE=mode,
                   KSU_LATE_LOAD="1", **extra)
        return subprocess.run([BASH, (self.root / name).as_posix(), *args], env=env,
                              capture_output=True, text=True, encoding="utf-8", timeout=20)

    def assert_failed_restore(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("回写完成！", result.stdout)
        self.assertTrue((self.bk / "skip").exists())
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertFalse((self.bk / "adsp_state").exists())
        self.assertFalse((self.root / "policy").exists(), "failure must stop before policy mutation")
        self.assertFalse((self.root / "remove").exists())
        self.assertFalse((self.bk / "uninstall_verified").exists())

    def test_readback_mismatch_is_failure(self):
        self.assert_failed_restore(self.run_script(mode="mismatch"))

    def test_stale_success_record_does_not_skip_hardware(self):
        (self.bk / "adsp_state").write_text("3250")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "adsp_write").read_text().strip(), "3250")
        self.assertGreaterEqual(len((self.root / "read_events").read_text().splitlines()), 2)
        self.assertFalse((self.bk / "restore_pending").exists())

    def test_stale_original_never_overrides_live_target(self):
        (self.bk / "adsp_orig.txt").write_text("3000")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "adsp_write").read_text().strip(), "3250")
        self.assertEqual((self.bk / "restore_target_mv").read_text().strip(), "3250")
        self.assertEqual((self.bk / "adsp_orig.txt").read_text(), "3000")
        self.assertTrue((self.root / "remove").exists())

    def test_live_target_failure_never_falls_back_to_valid_backup(self):
        result = self.run_script(mode="dt_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.params / "uv_target_mv").read_text(), "2800")
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertFalse((self.root / "remove").exists())
        self.assertTrue((self.bk / "restore_pending").exists())

    def test_target_change_after_write_retains_pending(self):
        with (self.root / "log.sh").open("a", encoding="utf-8") as output:
            output.write(r'''
uv_dt_orig() {
    _fake_written=$(command cat "$FAKE_ROOT/sys/module/uv2800/parameters/adsp_write")
    case "$_fake_written" in not-written) echo 3250 ;; *) echo 3300 ;; esac
}
''')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "adsp_write").read_text().strip(), "3250")
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertFalse((self.bk / "adsp_state").exists())
        self.assertFalse((self.root / "remove").exists())

    def test_service_restoration_obeys_voltage_gate(self):
        (self.bk / "skip").touch()
        for value in ("3100000", "0", "invalid"):
            with self.subTest(value=value):
                self.put("sys/class/power_supply/battery/voltage_now", value)
                result = self.run_script("service.sh")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.params / "uv_target_mv").read_text(), "2800")
                self.assertEqual((self.params / "uv_adsp_mv").read_text(), "2540")
                self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
                self.assertTrue((self.bk / "restore_pending").exists())
                self.assertFalse((self.root / "read_events").exists())

    def test_service_retries_do_not_clear_mount_failure(self):
        info = self.root / "proc/1/mountinfo"
        info.write_text("1 0 0:1 /chip_soc /capacity rw - sysfs sysfs rw\n")
        first = self.run_script()
        self.assertNotEqual(first.returncode, 0)
        retried = self.run_script("service.sh")
        self.assertNotEqual(retried.returncode, 0, retried.stdout + retried.stderr)
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertIn("chip_soc", info.read_text())
        self.assertFalse((self.root / "remove").exists())

    def test_binder_semantic_failures_never_schedule_removal(self):
        for mode in ("policy_get_exception", "policy_empty", "policy_set_exception", "policy_unchanged"):
            with self.subTest(mode=mode):
                self.put("policy", "true")
                result = self.run_script(mode=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.root / "policy").read_text(), "true")
                self.assertTrue((self.bk / "restore_pending").exists())
                self.assertFalse((self.root / "remove").exists())

    def test_shared_xml_and_unrelated_keys_are_preserved(self):
        xml = self.root / "data/system/oplus_devicepolicy_data_customize.xml"
        live = '<policies><entry key="unrelated" value="new"/></policies>'
        xml.write_text(live)
        (self.bk / "orig_state").write_text("existed")
        (self.bk / "devicepolicy_orig.xml").write_text('<policies><entry key="unrelated" value="old"/></policies>')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(xml.read_text(), live)
        self.assertEqual((self.root / "policy").read_text().strip(), "false")

    def test_invalid_old_policy_state_never_deletes_shared_xml(self):
        xml = self.root / "data/system/oplus_devicepolicy_data_customize.xml"
        xml.write_text('<policies><entry key="unrelated"/></policies>')
        (self.bk / "orig_state").write_text("corrupt")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(xml.read_text(), '<policies><entry key="unrelated"/></policies>')
        self.assertFalse((self.root / "remove").exists())
        self.assertFalse((self.root / "policy_events").exists())
        self.assertTrue((self.bk / "restore_pending").exists())

    def test_uninstall_failure_retains_policy_snapshot(self):
        (self.bk / "policy_orig").write_text("false")
        self.put("sys/class/power_supply/battery/voltage_now", "3100000")
        result = self.run_script("uninstall.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.bk / "policy_orig").read_text(), "false")
        self.assertTrue((self.bk / "restore_pending").exists())

    def test_failed_write_stops_restore(self):
        (self.params / "adsp_write").unlink()
        (self.params / "adsp_write").mkdir()
        self.assert_failed_restore(self.run_script())

    def test_read_error_ignores_old_record(self):
        (self.bk / "adsp_state").write_text("3250")
        self.assert_failed_restore(self.run_script(mode="read_error"))

    def test_request_errno_is_failure(self):
        (self.params / "adsp_read").unlink()
        (self.params / "adsp_read").mkdir()
        self.assert_failed_restore(self.run_script())

    def test_success_requires_live_read_even_when_value_already_matches(self):
        self.put("hardware_voltage", "3250")
        result = self.run_script(args=("--restore-only",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("回写完成！", result.stdout)
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertGreaterEqual(len((self.root / "read_events").read_text().splitlines()), 2)

    def test_default_action_schedules_verified_uninstall(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("一键安全卸载已安排", result.stdout)
        self.assertTrue((self.root / "remove").is_file())
        self.assertEqual((self.bk / "uninstall_verified").read_text().strip(), "3250")
        self.assertFalse((self.bk / "restore_pending").exists())

    def test_restore_only_preserves_module_and_does_not_schedule(self):
        result = self.run_script(args=("--restore-only",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "remove").exists())
        self.assertFalse((self.bk / "uninstall_verified").exists())

    def test_restore_only_does_not_cancel_existing_remove(self):
        (self.root / "remove").touch()
        result = self.run_script(args=("--restore-only",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "remove").exists())

    def test_old_remove_is_cancelled_before_failed_restore(self):
        (self.root / "remove").touch()
        updated = self.root / "data/adb/modules_update/uv2800"
        updated.mkdir(parents=True)
        (updated / "remove").touch()
        self.assert_failed_restore(self.run_script(mode="read_error"))
        self.assertFalse((updated / "remove").exists())
        result = self.run_script(args=("--restore-only",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "remove").exists())

    def test_failed_cancel_does_not_touch_hardware(self):
        (self.root / "remove").mkdir()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("撤销已有删除安排失败", result.stdout)
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertEqual((self.params / "uv_target_mv").read_text(), "2800")
        self.assertFalse((self.root / "read_events").exists())

    def test_low_missing_or_invalid_voltage_never_writes_or_schedules(self):
        for value in ("3299000", "0", "garbage", "99999999999999999999", None):
            with self.subTest(value=value):
                voltage = self.root / "sys/class/power_supply/battery/voltage_now"
                if value is None:
                    voltage.unlink()
                else:
                    voltage.write_text(value)
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
                self.assertEqual((self.params / "uv_target_mv").read_text(), "2800")
                self.assertFalse((self.root / "remove").exists())
                self.assertFalse((self.root / "read_events").exists())

    def test_voltage_must_exceed_factory_target(self):
        (self.bk / "adsp_orig.txt").write_text("3350")
        self.put("sys/class/power_supply/battery/voltage_now", "3350000")
        result = self.run_script(FAKE_DT="3350")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertFalse((self.root / "remove").exists())

    def test_3300mv_is_accepted_when_above_target(self):
        self.put("sys/class/power_supply/battery/voltage_now", "3300000")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "remove").exists())

    def test_unknown_factory_value_never_writes_or_schedules(self):
        (self.bk / "adsp_orig.txt").unlink()
        result = self.run_script(mode="dt_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertFalse((self.root / "remove").exists())
        self.assertFalse((self.root / "read_events").exists())

    def make_ksud(self, fail=False):
        cli = self.root / "fake-ksud"
        cli.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$FAKE_ROOT/ksud_calls"\n'
                       'test -f "$FAKE_ROOT/data/adb/uv2800_backup/uninstall_verified" || exit 9\n'
                       'touch "$FAKE_ROOT/remove"\n' + ('exit 1\n' if fail else 'exit 0\n'),
                       encoding="utf-8", newline="\n")
        cli.chmod(0o755)
        return cli.as_posix()

    def test_official_cli_is_used_after_verification(self):
        result = self.run_script(FAKE_KSUD=self.make_ksud())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "ksud_calls").read_text().strip(), "module uninstall uv2800")
        self.assertTrue((self.root / "remove").exists())

    def test_failed_scheduling_rolls_back_partial_marker(self):
        result = self.run_script(FAKE_KSUD=self.make_ksud(fail=True))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "remove").exists())
        self.assertFalse((self.bk / "uninstall_verified").exists())
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertNotIn("一键安全卸载已安排", result.stdout)

    def test_service_does_not_apply_after_removal_scheduled(self):
        (self.root / "remove").touch()
        result = self.run_script("service.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "uv_target_mv").read_text(), "2800")
        self.assertFalse((self.root / "policy").exists())
        self.assertFalse((self.root / "read_events").exists())

    def test_decoupling_invalidates_previous_uninstall_verification(self):
        (self.bk / "uninstall_verified").write_text("3250")
        result = self.run_script("service.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.bk / "uninstall_verified").exists())

    def test_mount_residue_or_unreadable_info_blocks_scheduling(self):
        for pid in ("1", "self"):
            with self.subTest(pid=pid):
                info = self.root / "proc" / pid / "mountinfo"
                clean = info.read_text()
                info.write_text("1 0 0:1 /chip_soc /capacity rw - sysfs sysfs rw\n")
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "remove").exists())
                info.unlink()
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "remove").exists())
                info.write_text(clean)

    def hide_kernel(self):
        hidden = self.root / "inactive_parameters"
        assert self.params.resolve().is_relative_to(self.root.resolve())
        assert hidden.resolve().is_relative_to(self.root.resolve())
        self.params.rename(hidden)

    def test_early_uninstall_distinguishes_verified_history(self):
        (self.bk / "skip").touch()
        (self.bk / "uninstall_verified").write_text("3250")
        (self.bk / "restore_target_mv").write_text("3250")
        (self.bk / "orig_state").write_text("absent")
        self.hide_kernel()
        result = self.run_script("uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("上次一键卸载已验证", result.stdout)
        self.assertFalse((self.bk / "restore_pending").exists())
        self.assertTrue((self.bk / "uninstall_verified").exists())

    def test_early_uninstall_without_verification_preserves_recovery_data(self):
        (self.bk / "orig_state").write_text("absent")
        self.hide_kernel()
        result = self.run_script("uninstall.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("退出码不具有阻止删除的作用", result.stdout)
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertTrue((self.bk / "orig_state").exists())
        self.assertTrue((self.bk / "adsp_orig.txt").exists())

    def test_live_uninstall_restores_without_nested_lock_or_new_removal(self):
        result = self.run_script("uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("卸载兜底已实时验证", result.stdout)
        self.assertEqual((self.bk / "uninstall_verified").read_text().strip(), "3250")
        self.assertFalse((self.root / "remove").exists())

    def test_dry_run_preserves_contaminated_backup(self):
        (self.bk / "adsp_orig.txt").write_text("2500")
        result = self.run_script(UV2800_DRYRUN="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.bk / "adsp_orig.txt").read_text(), "2500")
        self.assertFalse((self.bk / "adsp_orig.bad").exists())
        self.assertFalse((self.bk / "skip").exists())
        self.assertFalse((self.root / "read_events").exists())

    def test_dry_run_does_not_change_existing_removal_or_evidence(self):
        (self.root / "remove").touch()
        (self.bk / "uninstall_verified").write_text("3250")
        result = self.run_script(UV2800_DRYRUN="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "remove").exists())
        self.assertEqual((self.bk / "uninstall_verified").read_text(), "3250")
        self.assertFalse((self.root / "read_events").exists())

    def test_policy_process_failure_keeps_pending_and_does_not_claim_success(self):
        result = self.run_script(mode="policy_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("回写完成！", result.stdout)
        self.assertTrue((self.bk / "restore_pending").exists())

    def test_skip_without_device_still_sets_both_hook_targets(self):
        (self.bk / "skip").touch()
        result = self.run_script("service.sh", mode="read_error")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "uv_target_mv").read_text().strip(), "3250")
        self.assertEqual((self.params / "uv_adsp_mv").read_text().strip(), "3250")
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertFalse((self.root / "policy_events").exists())

    def test_skip_retries_and_clears_pending_only_after_verification(self):
        (self.bk / "skip").touch()
        (self.bk / "restore_pending").touch()
        result = self.run_script("service.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.bk / "restore_pending").exists())
        self.assertEqual((self.bk / "adsp_state").read_text().strip(), "3250")

    def test_decouple_readback_failure_invalidates_old_record(self):
        self.put("hardware_voltage", "3250")
        (self.bk / "adsp_state").write_text("3250")
        result = self.run_script("service.sh", mode="mismatch")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.bk / "adsp_state").exists())

    def test_failed_original_backup_stops_active_adsp_write(self):
        self.put("hardware_voltage", "3250")
        (self.bk / "adsp_orig.txt").unlink()
        (self.bk / "adsp_orig.txt").mkdir()
        result = self.run_script("service.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertFalse((self.bk / "adsp_state").exists())

    def test_syntax_and_lf(self):
        for source in SCRIPTS.glob("*.sh"):
            self.assertNotIn(b"\r", source.read_bytes(), source.name)
            result = subprocess.run([BASH, "-n", source.as_posix()], capture_output=True)
            self.assertEqual(result.returncode, 0, (source.name, result.stderr))

    def lock_source(self):
        # Original production helper, not the fixture's uv_lock override.
        source = SCRIPTS.joinpath("log.sh").read_text(encoding="utf-8")
        helper = self.root / "lock.sh"
        helper.write_text(source + '\nUV_BK="$FAKE_ROOT/lock-backup"\nuv_log() { echo "$*"; }\n',
                          encoding="utf-8", newline="\n")
        return helper

    def test_lock_timeout_is_nonzero(self):
        helper = self.lock_source()
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix())
        result = subprocess.run(
                           [BASH, "-c", '. "$1"; flock() { return 1; }; sleep() { :; }; uv_lock',
                            "test", helper.as_posix()], env=env, capture_output=True,
                           text=True, encoding="utf-8", timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("90s", result.stdout)

    def test_missing_lock_backend_fails_closed(self):
        helper = self.lock_source()
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix())
        result = subprocess.run(
            [BASH, "-c", '. "$1"; command() { return 1; }; uv_lock',
             "test", helper.as_posix()], env=env, capture_output=True,
            text=True, encoding="utf-8", timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("flock", result.stdout)

    def test_busybox_and_toybox_backend_selection(self):
        helper = self.lock_source()
        for backend in ("busybox", "toybox"):
            with self.subTest(backend=backend):
                env = dict(os.environ, FAKE_ROOT=self.root.as_posix(), BACKEND=backend)
                code = r'''
. "$1"
command() { [ "$1" = -v ] && [ "$2" = "$BACKEND" ]; }
busybox() {
    case "$1" in
        --list) echo flock ;;
        flock) [ "$2" = -n ] && [ "$3" = 9 ] ;;
        *) return 1 ;;
    esac
}
toybox() {
    case "$1" in
        --list) return 1 ;;
        flock) [ "$2" = -n ] && [ "$3" = 9 ] ;;
        '') echo 'cat flock ls' ;;
        *) return 1 ;;
    esac
}
uv_lock && echo "selected=$UV_FLOCK"
'''
                result = subprocess.run([BASH, "-c", code, "test", helper.as_posix()],
                                        env=env, capture_output=True, text=True,
                                        encoding="utf-8", timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("selected=" + backend, result.stdout)

    @unittest.skipUnless(HAS_FLOCK, "real flock is unavailable on this host")
    def test_real_lock_serializes_processes_and_releases_on_exit(self):
        helper = self.lock_source()
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix())
        code = '. "$1"; uv_lock || exit; echo "$2 start" >> "$FAKE_ROOT/events"; sleep .2; echo "$2 end" >> "$FAKE_ROOT/events"'
        processes = [subprocess.Popen([BASH, "-c", code, "test", helper.as_posix(), name],
                                      env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for name in ("A", "B")]
        for process in processes:
            _, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, error)
        events = (self.root / "events").read_text().splitlines()
        self.assertIn(events, [["A start", "A end", "B start", "B end"],
                               ["B start", "B end", "A start", "A end"]])
        code = '. "$1"; uv_lock || exit; echo ready; read -r -t 30 ignored'
        holder = subprocess.Popen([BASH, "-c", code, "test", helper.as_posix()], env=env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.assertEqual(holder.stdout.readline().strip(), b"ready")
        holder.terminate()
        holder.wait(timeout=5)
        holder.stdin.close()
        holder.stdout.close()
        result = subprocess.run([BASH, "-c", '. "$1"; uv_lock', "test", helper.as_posix()],
                                env=env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lock_falls_back_to_fd0_when_fd9_is_ebadf(self):
        """C17 adb-su 上下文：fd 9 未被子进程继承（EBADF），fd 0 必然继承。"""
        helper = self.lock_source()
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix())
        code = r'''
. "$1"
flock() {
    case "$2" in
        9) echo "flock: Bad file descriptor" >&2; return 1 ;;
        0) return 0 ;;
        *) return 1 ;;
    esac
}
sleep() { :; }
uv_lock && echo locked-via-fd0
[ ! -e "$FAKE_ROOT/.lockprobe" ] && echo probe-cleaned
'''
        result = subprocess.run([BASH, "-c", code, "test", helper.as_posix()],
                                env=env, capture_output=True, text=True,
                                encoding="utf-8", timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("locked-via-fd0", result.stdout)
        self.assertIn("probe-cleaned", result.stdout)

    def test_lock_fails_fast_when_fd0_also_rejects(self):
        """降级路径的 fd 0 也 EBADF 时必须立即失败，不能空转 90s。"""
        helper = self.lock_source()
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix())
        code = r'''
. "$1"
flock() {
    case "$2" in
        9|0) echo "flock: Bad file descriptor" >&2; return 1 ;;
        *) return 1 ;;
    esac
}
sleep() { :; }
uv_lock; echo "rc=$?"
'''
        result = subprocess.run([BASH, "-c", code, "test", helper.as_posix()],
                                env=env, capture_output=True, text=True,
                                encoding="utf-8", timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rc=1", result.stdout)
        self.assertNotIn("90s", result.stdout)  # fd 0 EBADF 走快速失败，不进入 90s 等待

    def test_lock_timeout_is_nonzero_after_probe(self):
        """探测后锁仍被占用：stderr 为空 → 走原有 90s 有界等待。"""
        helper = self.lock_source()
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix())
        result = subprocess.run(
                           [BASH, "-c", '. "$1"; flock() { return 1; }; sleep() { :; }; uv_lock',
                            "test", helper.as_posix()], env=env, capture_output=True,
                           text=True, encoding="utf-8", timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("90s", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
