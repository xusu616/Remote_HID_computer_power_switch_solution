# Remote HID Computer Power Switch Solution

[中文文档](README.md)

Turn a spare **rooted Android phone + Tailscale + Magisk module** into a remotely triggerable **USB HID keyboard (with USB `soft_connect` fallback)** plugged into a remote Linux/PC host, allowing you to wake the host from **Suspend-to-RAM (S3 / `s2idle`)** over Tailscale.

> Built for the scenario where a remote Arch Linux machine has a loose onboard Ethernet jack, relies on a USB Ethernet dongle that does not support Wake-on-LAN (WoL), and you do not want to buy extra IP-KVM hardware.  
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
  └── USB ConfigFS Gadget   (ffs.adb + hid.usb0 boot keyboard, bmAttributes=0xa0)
        │  (USB cable: /dev/hidg0 Left Shift + soft_connect fallback)
        ▼
[Remote Linux Host (S3 / s2idle suspended)]
```

### Why this design?
* **Not triggered by arbitrary Tailscale traffic**: Tailscale periodically sends DERP keepalives and MagicDNS probes; waking on any packet would constantly wake the PC. Only an authenticated HTTP request carrying a random 24-hex `token` triggers a wake.
* **Magisk native daemon instead of Termux**: Runs BusyBox `httpd` directly from `service.sh` with `/sys/power/wake_lock`, avoiding Android's app background killer.
* **Safe keypress + fallback**: Sends **Left Shift** (so an already-awake PC does not receive Enter or stray characters) with a `timeout 2` guard against blocked endpoint writes, and falls back to `/sys/class/udc/<udc>/soft_connect` re-enumeration if the UDC stays `suspended`.
* **Android `ueventd` & `init` quirks handled**: Automatically creates `/dev/hidg0` via `mknod` from `hid.usb0/dev`, encodes the 63-byte HID report descriptor with `base64 -d`, preserves `ffs.adb` alongside `hid.usb0`, and exports `/system/bin` in `PATH`.

---

## Quick Start

1. **Check Android kernel support**:
   ```bash
   su -c 'zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_USB_CONFIGFS|CONFIG_USB_F_HID"'
   ```
   You need `CONFIG_USB_F_HID=y` (or `=m`) and `CONFIG_USB_CONFIGFS_F_HID=y`.
2. **Download or build the module ZIP**:
   * Download `wake_bridge-v1.0.0.zip` from [GitLab Releases](https://gitlab.com/xusu616/remote_hid_computer_power_switch_solution/-/releases), or run `python3 scripts/build-module.py`.
3. **Flash in Magisk / KernelSU / APatch** and reboot.
4. **Inspect generated URL & token**:
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
