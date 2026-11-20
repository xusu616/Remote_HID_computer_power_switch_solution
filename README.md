# Remote HID Computer Power Switch Solution

[English](README.en.md)

将已 Root 的安卓手机通过 Magisk 模块配合 Tailscale 接入远程 Linux 主机 USB 口，模拟 HID 键盘（含 `soft_connect` 软重连兜底），远程唤醒处于 S3 / `s2idle` 挂起状态的电脑。

详见博客文章：
* [用 Root 安卓机做 Tailscale 远程 USB HID 唤醒器](https://xusu616.gitlab.io/2026/11/15/remote-hid-computer-power-switch-solution/)

## 快速使用

~~可能你需要关闭手机密码？~~
1. 检查手机内核支持 `CONFIG_USB_F_HID=y`（`zcat /proc/config.gz | grep USB_F_HID`）。
2. 在 [GitLab Releases](https://gitlab.com/xusu616/remote_hid_computer_power_switch_solution/-/releases) 下载模块 ZIP 刷入 Magisk 并重启（或运行 `python3 scripts/build-module.py` 打包）。
3. 手机安装并登录 Tailscale（设电池无限制、锁定后台、取消锁屏密码），建议配合 ACC 模块设置 `acc 60 40`。
4. 查看唤醒 URL 并远程访问：
   ```bash
   su -c "wake-bridge url"
   # 唤醒: http://<TAILSCALE_IP>:9876/cgi-bin/wake?token=<TOKEN>
   # 状态: http://<TAILSCALE_IP>:9876/cgi-bin/status?token=<TOKEN>
   ```

## 文档

* [Linux 端 USB 唤醒配置](docs/LINUX-USB-WAKEUP.md)
* [其他唤醒方案对比](docs/ALTERNATIVE-SOLUTIONS.md)

## License

[MIT](LICENSE)
