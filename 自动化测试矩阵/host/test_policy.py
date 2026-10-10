#!/usr/bin/env python3
"""Exercise the real policy library with AOSP service Parcel text and fake Binder.

No adb, Android services, mounts or real device files are accessed. The fixtures
model IOplusDevicePolicyManagerService transaction 1 (boolean) and 4 (String16).
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "模块源目录/policy.sh"
BASH = shutil.which("bash")
if not BASH and Path("C:/Program Files/Git/bin/bash.exe").exists():
    BASH = "C:/Program Files/Git/bin/bash.exe"

GET = {
    "true": "Result: Parcel(00000000 00000004 00720074 00650075 00000000)",
    "false": "Result: Parcel(00000000 00000005 00610066 0073006c 00000065)",
    "absent": "Result: Parcel(00000000 ffffffff)",
}
SET_OK = "Result: Parcel(00000000 00000001   '........')"
EXCEPTION = "Result: Parcel(ffffffff 00000001 00000078 '........x...')"

FAKE_BINDER = r'''
su() {
    printf '%s\n' "$*" >> "$FAKE_ROOT/calls"
    if [ -f "$FAKE_ROOT/process_error" ]; then return 23; fi
    case "$*" in
        '1000 -c service call oplusdevicepolicy 4 s16 oplus_diable_super_power_saving_mode i32 1')
            if [ -f "$FAKE_ROOT/wrote" ] && [ -f "$FAKE_ROOT/post_write_reply" ]; then
                cat "$FAKE_ROOT/post_write_reply"
            elif [ -f "$FAKE_ROOT/get_reply" ]; then
                cat "$FAKE_ROOT/get_reply"
            else
                case "$(cat "$FAKE_ROOT/state")" in
                    true) echo "Result: Parcel(00000000 00000004 00720074 00650075 00000000)" ;;
                    false) echo "Result: Parcel(00000000 00000005 00610066 0073006c 00000065)" ;;
                    absent) echo "Result: Parcel(00000000 ffffffff)" ;;
                    *) return 24 ;;
                esac
            fi ;;
        '1000 -c service call oplusdevicepolicy 1 s16 oplus_diable_super_power_saving_mode s16 true i32 1')
            fake_set true ;;
        '1000 -c service call oplusdevicepolicy 1 s16 oplus_diable_super_power_saving_mode s16 false i32 1')
            fake_set false ;;
        *) echo "unexpected transaction: $*" >&2; return 25 ;;
    esac
}
fake_set() {
    touch "$FAKE_ROOT/wrote"
    if [ ! -f "$FAKE_ROOT/freeze" ]; then printf '%s\n' "$1" > "$FAKE_ROOT/state"; fi
    if [ -f "$FAKE_ROOT/set_reply" ]; then
        cat "$FAKE_ROOT/set_reply"
    else
        echo "Result: Parcel(00000000 00000001 '........')"
    fi
}
'''


@unittest.skipUnless(BASH, "bash is required (Git Bash supported)")
class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uv2800-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bk = self.root / "backup"
        self.bk.mkdir()
        self.put("state", "false")

    def put(self, relative, text):
        (self.root / relative).write_text(text, encoding="utf-8", newline="\n")

    def run_policy(self, command, input_text=None):
        env = dict(os.environ, UV_BK=self.bk.as_posix(),
                   POLICY_SCRIPT=POLICY.as_posix(), FAKE_ROOT=self.root.as_posix())
        return subprocess.run(
            [BASH, "-c", '. "$POLICY_SCRIPT"\n' + FAKE_BINDER + "\n" + command],
            env=env, input=input_text, capture_output=True, text=True,
            encoding="utf-8", timeout=10,
        )

    def calls(self):
        path = self.root / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_getter_decodes_utf16_and_null(self):
        for expected, parcel in GET.items():
            with self.subTest(expected=expected):
                result = self.run_policy("uv_policy_parse get", parcel)
                self.assert_ok(result)
                self.assertEqual(result.stdout, expected + "\n")

    def test_multiline_offsets_and_ascii_columns(self):
        fixtures = {
            "true": """Result: Parcel(
  0x00000000: 00000000 00000004 00720074 00650075 '........t.r.u.e.'
  0x00000010: 00000000                            '....            ')
""",
            "false": """Result: Parcel(
  0x00000000: 00000000 00000005 00610066 0073006c '........f.a.l.s.'
  0x00000010: 00000065                            'e...            ')
""",
            "absent": "Result: Parcel(\n  0x00000000: 00000000 ffffffff '........')\n",
        }
        for expected, parcel in fixtures.items():
            with self.subTest(expected=expected):
                result = self.run_policy("uv_policy_parse get", parcel)
                self.assert_ok(result)
                self.assertEqual(result.stdout.strip(), expected)

    def test_setter_checks_boolean_return(self):
        self.assert_ok(self.run_policy("uv_policy_parse set", SET_OK))
        for parcel in ("Result: Parcel(00000000 00000000)",
                       "Result: Parcel(00000000 00000002)", GET["true"], EXCEPTION):
            with self.subTest(parcel=parcel):
                result = self.run_policy("uv_policy_parse set", parcel)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_rejects_empty_exception_malformed_and_extra_data(self):
        fixtures = [
            "", "Result: Parcel(NULL)", "Result: Parcel()", EXCEPTION,
            "service: Service oplusdevicepolicy does not exist",
            GET["true"] + " garbage", GET["true"] + "\n" + GET["true"],
            GET["true"][:-1],
            "Result: Parcel(00000000 00000004 00720074 00650075 00000000 00000000)",
            "Result: Parcel(00000000 00000005 00720074 00650075 00000000)",
            "Result: Parcel(00000000 00000004 00720074 00650075 ffffffff)",
            "Result: Parcel(00000000 00000004 00720074 00650075)",
            "Result: Parcel(00000000 00000000 00000000)",  # empty string is not false
            "Result: Parcel(00000000 00000004 0072007x 00650075 00000000)",
            "Result: Parcel(00000000 ffffffff 'true') trailing",
            "Result: Parcel(\n0x00000004: 00000000 ffffffff)",
            "Result: Parcel(\n0x00000000: 00000000 00000004 00720074 00650075\n"
            "0x00000014: 00000000)",
        ]
        for parcel in fixtures:
            with self.subTest(parcel=parcel):
                result = self.run_policy("uv_policy_parse get", parcel)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_read_uses_verified_transaction_four(self):
        self.put("state", "absent")
        result = self.run_policy("uv_policy_read")
        self.assert_ok(result)
        self.assertEqual(result.stdout.strip(), "absent")
        self.assertEqual(self.calls(), [
            "1000 -c service call oplusdevicepolicy 4 s16 oplus_diable_super_power_saving_mode i32 1"
        ])

    def test_apply_and_restore_preserve_original_false(self):
        result = self.run_policy("uv_policy_apply && uv_policy_apply && uv_policy_restore")
        self.assert_ok(result)
        self.assertEqual((self.bk / "policy_orig").read_text().strip(), "false")
        self.assertEqual((self.bk / "policy_orig_source").read_text().strip(), "live")
        self.assertEqual((self.root / "state").read_text().strip(), "false")
        self.assertEqual(sum("oplusdevicepolicy 1 " in call for call in self.calls()), 2)

    def test_preexisting_true_is_preserved(self):
        self.put("state", "true")
        result = self.run_policy("uv_policy_apply && uv_policy_restore")
        self.assert_ok(result)
        self.assertEqual((self.bk / "policy_orig").read_text().strip(), "true")
        self.assertEqual((self.root / "state").read_text().strip(), "true")
        self.assertFalse(any("oplusdevicepolicy 1 " in call for call in self.calls()))

    def test_absent_original_is_explicit_default_false_not_fake_removal(self):
        self.put("state", "absent")
        result = self.run_policy("uv_policy_apply && uv_policy_restore")
        self.assert_ok(result)
        self.assertEqual((self.bk / "policy_orig").read_text().strip(), "absent")
        self.assertEqual((self.root / "state").read_text().strip(), "false")
        self.assertIn("显式 false", result.stderr)
        self.assertFalse(any("oplusdevicepolicy 6 " in call for call in self.calls()))

    def test_legacy_migration_never_replaces_shared_xml(self):
        original = '<policy><entry name="other" value="old"/></policy>'
        live = '<policy><entry name="other" value="new"/><unknown>keep &amp; x</unknown></policy>'
        (self.bk / "orig_state").write_text("existed")
        (self.bk / "devicepolicy_orig.xml").write_text(original)
        self.put("shared.xml", live)
        self.put("state", "true")
        result = self.run_policy("uv_policy_apply && uv_policy_restore")
        self.assert_ok(result)
        self.assertEqual((self.bk / "policy_orig").read_text().strip(), "false")
        self.assertEqual((self.bk / "policy_orig_source").read_text().strip(), "legacy-default-false")
        self.assertEqual((self.root / "shared.xml").read_text(), live)
        self.assertEqual((self.bk / "devicepolicy_orig.xml").read_text(), original)
        self.assertEqual((self.bk / "orig_state").read_text(), "existed")

    def test_restore_without_new_backup_records_legacy_default(self):
        self.put("state", "true")
        result = self.run_policy("uv_policy_restore")
        self.assert_ok(result)
        self.assertEqual((self.root / "state").read_text().strip(), "false")
        self.assertEqual((self.bk / "policy_orig_source").read_text().strip(), "legacy-default-false")

    def test_corrupt_original_is_not_overwritten(self):
        (self.bk / "policy_orig").write_text("unknown")
        for operation in ("uv_policy_apply", "uv_policy_restore"):
            with self.subTest(operation=operation):
                result = self.run_policy(operation)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.bk / "policy_orig").read_text(), "unknown")
                self.assertFalse((self.root / "wrote").exists())

    def test_corrupt_legacy_state_fails_without_mutating_any_backup(self):
        (self.bk / "orig_state").write_text("corrupted")
        (self.bk / "devicepolicy_orig.xml").write_text("<keep>original</keep>")
        self.put("state", "true")
        for modern_backup in (False, True):
            if modern_backup:
                (self.bk / "policy_orig").write_text("false")
            for operation in ("uv_policy_apply", "uv_policy_restore"):
                with self.subTest(operation=operation, modern_backup=modern_backup):
                    result = self.run_policy(operation)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual((self.bk / "orig_state").read_text(), "corrupted")
                    self.assertEqual((self.bk / "devicepolicy_orig.xml").read_text(), "<keep>original</keep>")
                    self.assertEqual((self.bk / "policy_orig").exists(), modern_backup)
                    self.assertFalse((self.root / "wrote").exists())
                    self.assertEqual(self.calls(), [])

    def test_getter_exception_with_process_success_stops_before_write(self):
        self.put("get_reply", EXCEPTION)
        for operation in ("uv_policy_apply", "uv_policy_restore"):
            with self.subTest(operation=operation):
                result = self.run_policy(operation)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "wrote").exists())
                self.assertFalse((self.bk / "policy_orig").exists())

    def test_setter_invalid_reply_keeps_original_backup(self):
        self.put("freeze", "1")
        for reply in (EXCEPTION, "", "Result: Parcel(00000000 00000000)",
                      "Result: Parcel(00000000 00000001 00000000)"):
            with self.subTest(reply=reply):
                self.put("set_reply", reply)
                result = self.run_policy("uv_policy_apply")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.bk / "policy_orig").read_text().strip(), "false")
                self.assertEqual((self.root / "state").read_text().strip(), "false")

    def test_setter_success_with_unchanged_readback_fails(self):
        self.put("freeze", "1")
        result = self.run_policy("uv_policy_apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("读回 false，期望 true", result.stderr)
        self.assertEqual((self.bk / "policy_orig").read_text().strip(), "false")

    def test_malformed_post_write_getter_fails(self):
        self.put("post_write_reply", "Result: Parcel(NULL)")
        result = self.run_policy("uv_policy_apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.bk / "policy_orig").exists())

    def test_process_error_is_not_silenced(self):
        self.put("process_error", "1")
        result = self.run_policy("uv_policy_apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "wrote").exists())
        self.assertFalse((self.bk / "policy_orig").exists())

    def test_failed_backup_stops_before_setter(self):
        (self.bk / "policy_orig").mkdir()
        result = self.run_policy("uv_policy_apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "wrote").exists())


if __name__ == "__main__":
    unittest.main()
