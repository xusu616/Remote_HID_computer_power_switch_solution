"""Run the real Action/helper control flow with mocked Android and USB boundaries."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
BASH = Path(r"D:\Git\Git\bin\bash.exe")
if not BASH.exists():
    BASH = Path(shutil.which("bash") or "")


def shell_path(path):
    """Git Bash needs /c/... for paths stored in shell variables and redirects."""
    value = path.as_posix()
    if path.drive:
        return f"/{path.drive[0].lower()}{value[2:]}"
    return value


class ActionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="action-test-", dir=PROJECT / "tests")
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.wake = self.root / "wake-bridge"
        self.wake.mkdir()
        (self.root / "system/bin").mkdir(parents=True)
        self.calls = self.root / "calls"
        self.state = self.root / "usb-state"
        self.state.write_text("configured\n", encoding="utf-8")
        self.config = self.data / "config.env"
        self.config.write_text(
            "TOKEN=TEST_TOKEN_MUST_NOT_LEAK\nKEEP_ADB=2\nAUTO_TAILSCALE_ON_BOOT=1\n",
            encoding="utf-8",
        )
        common = f"DATA_DIR='{shell_path(self.data)}'\n" + r'''
BB=bb
bb() {
    case "$1" in
        sh) shift; bash "$@" ;;
        sleep) printf 'wait %s\n' "$2" >> "$CALLS_PATH" ;;
        *) command "$@" ;;
    esac
}
load_config() { . "$DATA_DIR/config.env"; }
detect_udc() { echo test_udc; }
keep_adb_label() { printf '%s\n' "$1"; }
pm() { echo package:/data/app/com.tailscale.ipn/base.apk; }
dumpsys() {
    if [ -f "$DATA_DIR/vpn-connected" ]; then
        printf '  * ServiceRecord{abc u0 com.tailscale.ipn/.IPNService}\n    isForeground=true foregroundId=1\n'
    else
        printf '  * ServiceRecord{abc u0 com.tailscale.ipn/.IPNService}\n    isForeground=false foregroundId=0\n'
    fi
}
am() {
    printf 'broadcast %s\n' "$*" >> "$CALLS_PATH"
    if [ "${VPN_FAIL:-0}" != 0 ]; then return "$VPN_FAIL"; fi
    : > "$DATA_DIR/vpn-connected"
    echo 'Broadcast completed'
}
'''
        (self.wake / "common.sh").write_text(common, encoding="utf-8")
        action = (PROJECT / "magisk-module/action.sh").read_text(encoding="utf-8")
        # Replace only the sysfs I/O boundary. The action's control flow is unchanged.
        action = action.replace('"/sys/class/udc/$UDC/state"', '"$TEST_UDC_STATE"')
        (self.root / "action.sh").write_text(action, encoding="utf-8")
        shutil.copy2(
            PROJECT / "magisk-module/wake-bridge/start-tailscale.sh",
            self.wake / "start-tailscale.sh",
        )
        (self.wake / "setup-hid.sh").write_text(
            '. "$COMMON_TEST_PATH"\nload_config\n'
            'printf "setup %s KEEP_ADB=%s\\n" "$*" "$KEEP_ADB" >> "$CALLS_PATH"\n'
            'exit "${HID_RC:-0}"\n',
            encoding="utf-8",
        )
        (self.root / "system/bin/wake-bridge").write_text(
            'printf "status %s\\n" "$*" >> "$CALLS_PATH"\n'
            'echo status_without_token\nexit "${STATUS_RC:-0}"\n',
            encoding="utf-8",
        )
        self.env = dict(os.environ)
        self.env.update(
            CALLS_PATH=shell_path(self.calls),
            TEST_UDC_STATE=shell_path(self.state),
            COMMON_TEST_PATH=shell_path(self.wake / "common.sh"),
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_action(self):
        before = self.config.read_bytes()
        result = subprocess.run(
            [str(BASH), shell_path(self.root / "action.sh")],
            env=self.env,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(self.config.read_bytes(), before)
        self.assertNotIn("TEST_TOKEN_MUST_NOT_LEAK", result.stdout + result.stderr)
        self.assertTrue((self.data / "action.log").exists(), result.stderr)
        self.assertNotIn(
            "TEST_TOKEN_MUST_NOT_LEAK",
            (self.data / "action.log").read_text(encoding="utf-8"),
        )
        calls = self.calls.read_text(encoding="utf-8").splitlines()
        self.assertFalse(any("wake.sh" in c or "daemon" in c for c in calls))
        return result, calls

    def test_success_starts_vpn_then_repairs_current_adb_mode(self):
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls[0].startswith("broadcast broadcast --user 0 --include-stopped-packages"))
        self.assertEqual(calls[1:], ["wait 10", "setup --force KEEP_ADB=2", "status status"])

    def test_vpn_failure_still_attempts_usb_repair(self):
        self.env["VPN_FAIL"] = "7"
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls[-2:], ["setup --force KEEP_ADB=2", "status status"])
        self.assertIn("Tailscale startup failed", result.stdout)

    def test_manual_start_overrides_boot_disabled_without_editing_config(self):
        self.config.write_text(
            "TOKEN=TEST_TOKEN_MUST_NOT_LEAK\nKEEP_ADB=1\nAUTO_TAILSCALE_ON_BOOT=0\n",
            encoding="utf-8",
        )
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 0)
        self.assertTrue(calls[0].startswith("broadcast "))
        self.assertIn("setup --force KEEP_ADB=1", calls)
        self.calls.write_text("", encoding="utf-8")
        boot_result = subprocess.run(
            [str(BASH), shell_path(self.wake / "start-tailscale.sh")],
            env=self.env, text=True, encoding="utf-8", capture_output=True, timeout=30,
        )
        self.assertEqual(boot_result.returncode, 0)
        self.assertIn("tailscale_start_result=disabled", boot_result.stdout)
        self.assertEqual(self.calls.read_text(encoding="utf-8"), "")

    def test_suspended_host_refuses_rebind_and_gives_manual_recovery(self):
        self.state.write_text("suspended\n", encoding="utf-8")
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 2)
        self.assertFalse(any(c.startswith("setup ") for c in calls))
        self.assertIn("Resume the host manually", result.stdout)
        self.assertIn("physically unplug and reconnect", result.stdout)
        self.assertEqual(calls[-1], "status status")

    def test_successful_status_does_not_hide_hid_failure(self):
        self.env["HID_RC"] = "9"
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 9)
        self.assertEqual(calls[-1], "status status")
        self.assertIn("hid_result=9", result.stdout)

    def test_first_failure_exit_code_survives_later_failures(self):
        (self.wake / "start-tailscale.sh").write_text(
            'echo manual_vpn_failed\nexit 7\n', encoding="utf-8"
        )
        self.env.update(HID_RC="9", STATUS_RC="11")
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 7)
        self.assertIn("tailscale_result=7", result.stdout)
        self.assertIn("hid_result=9", result.stdout)
        self.assertIn("status_result=11", result.stdout)
        self.assertEqual(calls, ["setup --force KEEP_ADB=2", "status status"])

    def test_unreadable_usb_state_does_not_rebind(self):
        self.state.unlink()
        result, calls = self.run_action()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(c.startswith("setup ") for c in calls))
        self.assertIn("cannot read the controller state", result.stdout)

    def test_helper_rejects_unknown_or_extra_arguments(self):
        for args in (["--unknown"], ["--manual", "extra"]):
            result = subprocess.run(
                [str(BASH), shell_path(self.wake / "start-tailscale.sh"), *args],
                env=self.env, text=True, encoding="utf-8", capture_output=True, timeout=30,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("Usage:", result.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
