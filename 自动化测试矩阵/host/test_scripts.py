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
        for original in SCRIPTS.glob("*.sh"):
            source = original.read_text(encoding="utf-8")
            for absolute in ("/sys/", "/data/"):
                source = source.replace(absolute, self.root.as_posix() + absolute)
            (self.root / original.name).write_text(source, encoding="utf-8", newline="\n")
        # Emulate only Android commands/sysfs callbacks, retaining production control flow.
        with (self.root / "log.sh").open("a", encoding="utf-8", newline="\n") as output:
            output.write(r'''
uv_log() { echo "LOG $*"; }
uv_log_sep() { :; }
uv_capture_dev() { :; }
uv_dt_orig() { echo 3250; }
uv_unbind_capacity() { return 0; }
lsmod() { echo "uv2800 100 0"; }
sleep() { :; }
su() {
    [ "$FAKE_MODE" = policy_error ] && return 1
    case "$*" in
        *"s16 true"*) echo true > "$FAKE_ROOT/policy" ;;
        *"s16 false"*) echo false > "$FAKE_ROOT/policy" ;;
        *) echo 'Result: Parcel(00000000 00000001)' ;;
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

    def run_script(self, name="action.sh", mode="success", **extra):
        env = dict(os.environ, FAKE_ROOT=self.root.as_posix(), FAKE_MODE=mode,
                   KSU_LATE_LOAD="1", **extra)
        return subprocess.run([BASH, (self.root / name).as_posix()], env=env,
                              capture_output=True, text=True, encoding="utf-8", timeout=20)

    def assert_failed_restore(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("回写完成！", result.stdout)
        self.assertTrue((self.bk / "skip").exists())
        self.assertTrue((self.bk / "restore_pending").exists())
        self.assertFalse((self.bk / "adsp_state").exists())
        self.assertFalse((self.root / "policy").exists(), "failure must stop before policy mutation")

    def test_readback_mismatch_is_failure(self):
        self.assert_failed_restore(self.run_script(mode="mismatch"))

    def test_stale_success_record_does_not_skip_hardware(self):
        (self.bk / "adsp_state").write_text("3250")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.params / "adsp_write").read_text().strip(), "3250")
        self.assertGreaterEqual(len((self.root / "read_events").read_text().splitlines()), 2)
        self.assertFalse((self.bk / "restore_pending").exists())

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
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("回写完成！", result.stdout)
        self.assertEqual((self.params / "adsp_write").read_text(), "not-written")
        self.assertGreaterEqual(len((self.root / "read_events").read_text().splitlines()), 2)

    def test_dry_run_preserves_contaminated_backup(self):
        (self.bk / "adsp_orig.txt").write_text("2500")
        result = self.run_script(UV2800_DRYRUN="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.bk / "adsp_orig.txt").read_text(), "2500")
        self.assertFalse((self.bk / "adsp_orig.bad").exists())
        self.assertFalse((self.bk / "skip").exists())
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
        self.assertEqual((self.root / "policy").read_text().strip(), "false")

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
