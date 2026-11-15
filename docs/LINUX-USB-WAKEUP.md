# 目标 Linux 电脑端 USB 唤醒配置与排查指南

在将配置好 `wake_bridge` 模块的安卓手机通过 USB 线插到远程 Arch / Linux 主机后，请按下面步骤完成主机侧验证与持久化设置。

---

## 1. 确认挂起模式（S3 内存挂起 vs S4 磁盘休眠）

```bash
cat /sys/power/mem_sleep
```

* `[deep]`：传统 S3 挂起到内存（最常见）；
* `[s2idle]`：现代待机（Modern Standby）；
* **注意**：USB 键盘按键与 USB 插入信号通常仅对 **S3 / `s2idle`** 稳定有效；如果主机进入了 **挂起到磁盘（Hibernate / S4）**，多数主板会切断 USB 唤醒支持。

---

## 2. 验证 Linux 已识别手机的 HID 键盘接口

把手机插到目标 Linux 电脑后执行：

```bash
lsusb
dmesg | grep -iE "hid|input|18d1" | tail -n 20
```

正常情况下能看到手机作为复合设备（ADB + HID Keyboard）枚举出了 `hid-generic` 输入设备。接着测试在系统清醒状态下触发一次 `wake`：

```bash
curl "http://<手机Tailscale_IP>:9876/cgi-bin/wake?token=<TOKEN>"
```

预期输出中应看到 `hid=ok`（而不是 `write_failed_or_suspended`）。

> 注：如果在 **Windows** 上插过同一个 `VID:PID` 的单接口 ADB，Windows 注册表可能缓存旧接口数量而不去轮询第二个 HID 接口；**Linux 每次插入都会重新读取完整描述符**，不会出现此缓存问题。

---

## 3. 检查并开启 BIOS 与 Linux USB 唤醒

### 3.1 BIOS / UEFI 设置
* 开启 **Wake on USB** / **USB Resume from S3**（不同主板名称略异）；
* 关闭 **ErP / EuP Ready** 节能选项（否则部分主板在休眠后会直接切断 USB 5V 待机供电，也无法监听 `Remote Wakeup`）。

### 3.2 Linux 内核 ACPI 与 Sysfs 唤醒开关
1. 查看当前允许唤醒的 ACPI 设备：
   ```bash
   cat /proc/acpi/wakeup
   ```
   找到 USB 控制器（常见名称为 `XHC`、`XHCI`、`EHC1`、`USB1` 等），确认对应 S3 行的状态为 `*enabled`。若为 `*disabled`，可先临时切换测试：
   ```bash
   echo XHC | sudo tee /proc/acpi/wakeup
   ```

2. 找到手机对应的 USB 设备路径并确认 `power/wakeup` 为 `enabled`：
   ```bash
   grep -H . /sys/bus/usb/devices/*/product 2>/dev/null
   # 假设手机对应设备为 1-2，查看并开启其本身及所属控制器 usb1 的唤醒：
   cat /sys/bus/usb/devices/1-2/power/wakeup
   echo enabled | sudo tee /sys/bus/usb/devices/1-2/power/wakeup
   echo enabled | sudo tee /sys/bus/usb/devices/usb1/power/wakeup
   ```

---

## 4. 持久化配置（udev 规则与 systemd 服务）

`/sys/.../power/wakeup` 与 `/proc/acpi/wakeup` 在重启后会恢复默认值，需要持久化：

### 4.1 持久化 USB 设备唤醒（`/etc/udev/rules.d/90-usb-wake-bridge.rules`）
先用 `lsusb` 查看手机的 `idVendor:idProduct`（例如默认保留 ADB 时为 `18d1:4ee7`）：

```udev
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="4ee7", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
```

重载规则：
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### 4.2 若 `/proc/acpi/wakeup` 的 `XHC` 重启后会变回 `disabled`
创建一个开机执行一次的 systemd unit（`/etc/systemd/system/enable-xhc-wakeup.service`）：

```ini
[Unit]
Description=Enable XHC ACPI wakeup for USB HID bridge
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'grep -q "^XHC.*\*disabled" /proc/acpi/wakeup && echo XHC > /proc/acpi/wakeup || true'

[Install]
WantedBy=multi-user.target
```

启用该服务：
```bash
sudo systemctl enable --now enable-xhc-wakeup.service
```

---

## 5. 实测休眠唤醒

```bash
systemctl suspend
```

等待几秒让电脑彻底进入挂起状态，然后从另一台连着 Tailscale 的设备访问 `wake` URL。观察电脑是否唤醒以及返回中的 `state_before`、`hid`、`soft_reconnect`、`state_after` 字段。
