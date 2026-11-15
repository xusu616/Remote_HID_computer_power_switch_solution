# Remote HID Computer Power Switch Solution

[中文](README.md)

A Magisk / KernelSU / APatch module that turns a rooted Android phone into a Tailscale-reachable USB HID keyboard (with `soft_connect` fallback) to wake suspended S3 / `s2idle` Linux hosts.

Detailed write-up & troubleshooting notes:
* [Blog Post (Chinese)](https://xusu616.gitlab.io/2026/11/15/remote-hid-computer-power-switch-solution/)

## Quick Start

1. Verify Android kernel support: `zcat /proc/config.gz | grep USB_F_HID` (`y` or `m`).
2. Download the module ZIP from [GitLab Releases](https://gitlab.com/xusu616/remote_hid_computer_power_switch_solution/-/releases) (or run `python3 scripts/build-module.py`), flash in Magisk, and reboot.
3. Install **Tailscale** on the phone (disable battery optimization, lock in Recents, disable lock-screen PIN), and optionally pair with **ACC** (`acc 60 40`).
4. Print endpoints and trigger remotely over Tailscale:
   ```bash
   su -c "wake-bridge url"
   # Wake:   http://<TAILSCALE_IP>:9876/cgi-bin/wake?token=<TOKEN>
   # Status: http://<TAILSCALE_IP>:9876/cgi-bin/status?token=<TOKEN>
   ```

## Docs

* [Linux USB Wakeup Setup](docs/LINUX-USB-WAKEUP.md)
* [Alternative Solutions Comparison](docs/ALTERNATIVE-SOLUTIONS.md)

## License

[MIT](LICENSE)
