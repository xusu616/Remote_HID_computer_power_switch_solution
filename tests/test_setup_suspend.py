"""Exercise real USB repair flow when the host suspends during Android ADB init."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_action import BASH, PROJECT, shell_path


class SetupSuspendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='setup-suspend-', dir=PROJECT / 'tests')
        self.root = Path(self.temp.name)
        self.gadget = self.root / 'gadget'
        self.config = self.gadget / 'configs/b.1'
        self.config.mkdir(parents=True)
        self.udc = self.gadget / 'UDC'
        self.udc.write_text('test_udc\n', encoding='utf-8')
        self.state = self.root / 'usb-state'
        self.state.write_text('configured\n', encoding='utf-8')
        self.ffs = self.root / 'ffs'
        self.ffs.mkdir()
        (self.ffs / 'ep0').touch()
        (self.root / 'common.sh').write_text(r'''
DATA_DIR="$TEST_DATA_DIR"
BB=bb
bb() {
    case "$1" in
        usleep) return 0 ;;
        *) command "$@" ;;
    esac
}
load_config() { KEEP_ADB=1; USB_PRODUCT_ID=; }
detect_udc() { echo test_udc; }
detect_usb_cfg() { echo "$TEST_USB_CONFIG"; }
normalize_keep_adb() { echo "$1"; }
want_adb_in_gadget() { return 0; }
getprop() {
    case "$1" in
        sys.usb.config) echo adb ;;
        init.svc.adbd) echo running ;;
        sys.usb.ffs.ready) echo 1 ;;
        sys.usb.state)
            if [ "$SUSPEND_DURING_ADB_INIT" = 1 ]; then
                echo suspended > "$TEST_UDC_STATE"
            fi
            echo adb ;;
    esac
}
setprop() { return 0; }
''', encoding='utf-8')
        script = (PROJECT / 'magisk-module/wake-bridge/setup-hid.sh').read_text(encoding='utf-8')
        # Redirect hardware I/O to the fixture; preserve the complete repair control flow.
        script = script.replace('G1="/config/usb_gadget/g1"', 'G1="$TEST_GADGET_ROOT"')
        script = script.replace('"/sys/class/udc/$UDC/state"', '"$TEST_UDC_STATE"')
        script = script.replace('/dev/usb-ffs/adb', shell_path(self.ffs))
        self.script = self.root / 'setup-hid.sh'
        self.script.write_text(script, encoding='utf-8')
        self.environment = dict(os.environ,
            TEST_DATA_DIR=shell_path(self.root / 'data'),
            TEST_GADGET_ROOT=shell_path(self.gadget),
            TEST_USB_CONFIG=shell_path(self.config),
            TEST_UDC_STATE=shell_path(self.state),
            SUSPEND_DURING_ADB_INIT='0')

    def tearDown(self):
        self.temp.cleanup()

    def run_repair(self):
        return subprocess.run([str(BASH), str(self.script), '--force'],
            env=self.environment, capture_output=True, text=True, encoding='utf-8', timeout=10)

    def assert_link_preserved(self, result, code):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertEqual(self.udc.read_text(encoding='utf-8'), 'test_udc\n')
        self.assertFalse((self.root / 'data/setup.lock').exists())

    def test_suspend_during_adb_initialization_preserves_usb_link(self):
        self.environment['SUSPEND_DURING_ADB_INIT'] = '1'
        self.assert_link_preserved(self.run_repair(), 2)
        self.assertEqual(self.state.read_text(encoding='utf-8').strip(), 'suspended')

    def test_initially_suspended_preserves_usb_link(self):
        self.state.write_text('suspended\n', encoding='utf-8')
        self.assert_link_preserved(self.run_repair(), 2)

    def test_unreadable_state_preserves_usb_link(self):
        self.state.unlink()
        self.assert_link_preserved(self.run_repair(), 1)


if __name__ == '__main__':
    unittest.main()
