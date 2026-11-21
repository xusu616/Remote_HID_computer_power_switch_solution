# Remote HID Computer Power Switch Solution

[中文文档](README.md)

Turn a spare **rooted Android phone + Tailscale + Magisk module** into a remotely triggerable **USB HID keyboard** plugged into a remote Linux/PC host, allowing you to wake the host from **Suspend-to-RAM (S3 / `s2idle`)** over Tailscale.

> Built for the scenario where a remote Arch Linux machine has a loose onboard Ethernet jack, relies on a USB Ethernet dongle that does not support Wake-on-LAN (WoL), and you do not want to buy extra IP-KVM hardware.\
> Verified on **Redmi 4X (`santoni`) · LineageOS 18.1 · Linux 4.19.325 · Magisk + ACC**.

---

## Architecture

```text
[Remote Phone / Laptop]
        │  (Tailscale mesh: 100.x.y.z)
        ▼
[Rooted Android Phone (wake_bridge Magisk module)]
  ├── Android Tailscale App (keeps mesh connectivity online)
  ├── BusyBox httpd :9876   (native root daemon + token auth)
  ├── ACC Magisk module     (caps charge between 40%–60% to prevent battery swelling)
  └── USB ConfigFS HID      (hid.usb0 boot keyboard + optional ffs.adb, bmAttributes=0xa0)
        │  (USB cable: /dev/hidg0 Left Shift + controlled HID repair)
        ▼
[Remote Linux Host (S3 / s2idle suspended)]
```

### Why this design?
* **Not triggered by arbitrary Tailscale traffic**: Tailscale periodically sends DERP keepalives and MagicDNS probes; waking on any packet would constantly wake the PC. Only an authenticated HTTP request carrying a random 24-hex `token` triggers a wake.
* **Root HTTP daemon**: Runs BusyBox `httpd` directly from `service.sh`. `DAEMON_WAKE_LOCK=1` and `HID_WATCHDOG=1` remain the defaults. Idle suspend is configurable and requires device testing; see [power and Tailscale configuration](docs/POWER-AND-TAILSCALE.md).
* **Serialized wake and suspended-link protection**: Sends **Left Shift** with a two-second timeout per write. It keeps the UDC link intact while USB is suspended and performs controlled HID repair only after the host is configured and writes still fail.
* **Android `ueventd` & `init` quirks handled**: Creates `/dev/hidg0` from `hid.usb0/dev`, encodes the HID descriptor with `base64 -d`, uses bounded builtin `printf` for key reports, and supports `KEEP_ADB=0/1/2` while exporting the system tools in `PATH`.
* **One-time Tailscale startup**: `AUTO_TAILSCALE_ON_BOOT=1` checks the foreground `IPNService`, skips an already-running service, or sends an explicit `CONNECT_VPN` request and checks once after ten seconds. Login and VPN consent remain manual; no VPN polling loop is added.

---

## Quick Start

1. **Check Android kernel support**:
   ```bash
   su -c 'zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_USB_CONFIGFS|CONFIG_USB_F_HID"'
   ```
   You need `CONFIG_USB_F_HID=y` (or `=m`) and `CONFIG_USB_CONFIGFS_F_HID=y`.
2. **Download or build the module ZIP**:
   * Run `python3 scripts/build-module.py` to build `wake_bridge-v1.0.11.zip`. Published packages are available from [GitLab Releases](https://gitlab.com/xusu616/remote_hid_computer_power_switch_solution/-/releases); use the version actually listed there.
3. **Flash in Magisk / KernelSU / APatch** and reboot.
4. **Inspect the protected configuration and explicit control URL** (installation output and `status` omit the token):
   ```bash
   su -c "wake-bridge url"
   su -c "wake-bridge status"
   ```
5. **Android reliability & battery care**:
   * Install & log into **Tailscale**, disable battery optimization for Tailscale, lock it in Recents, and enable auto-start.
   * **Disable the lock screen PIN/pattern** on the dedicated bridge phone so FBE does not block Wi-Fi/Tailscale after an unexpected reboot.
   * Use the **ACC Magisk module** (`acc 60 40`) to keep battery charge between `40%–60%`.
6. **Configure USB wakeup on the target Linux host**: see [docs/LINUX-USB-WAKEUP.md](docs/LINUX-USB-WAKEUP.md).

---

## Module Action

Click **Action** on the module page to check/start Tailscale once, repair ADB/HID using the current `KEEP_ADB` configuration, and display status. This is an explicit manual request, so it runs even when `AUTO_TAILSCALE_ON_BOOT=0` without changing that option or login state.

A Tailscale failure does not prevent the independent USB repair; each result is reported and failures are retained in `/data/adb/wake-bridge/action.log`, without printing the token. If the host USB link is `suspended`, repair is skipped to preserve the link; resume the host manually or physically reconnect USB before retrying. Action sends no HID keys and changes no CPU/power settings. Wired ADB may disconnect briefly during USB re-enumeration.

---

## Remote Endpoints

* **Check status (non-intrusive)**:
  `http://<TAILSCALE_IP>:9876/cgi-bin/status?token=<TOKEN>`
* **Trigger wake**:
  `http://<TAILSCALE_IP>:9876/cgi-bin/wake?token=<TOKEN>`

---

## Alternative Solutions

See [docs/ALTERNATIVE-SOLUTIONS.md](docs/ALTERNATIVE-SOLUTIONS.md) for a comparison with IP-KVM (`NanoKVM-PCIe`, `GL.iNet Comet`), `Raspberry Pi Zero 2 W`, PCIe NIC WoL, Fingerbot, and why Bluetooth HID is not recommended.

## License

[MIT License](LICENSE)

For Windows ADB/HID driver ownership, tested device identity settings, and wake limits, see [Windows HID recognition and wake](docs/WINDOWS-HID.md).

On 2026-11-21, the test PC entered Modern Standby and resumed from the phone's HID report after about 30 seconds; event 507 reported `Input Keyboard`. `scripts/sleep-windows-s0.ps1` sends one monitor-power request to a hidden window. DRIPS residency remained zero in this short test, and the phone held a temporary timer wake lock, so deep-idle power consumption and remote delivery while the phone is fully suspended remain unverified.
