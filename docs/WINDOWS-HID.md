# Windows HID 识别与唤醒

## 模块“操作”按钮

`action.sh` 先检查或启动 Tailscale，再按现有 `KEEP_ADB` 配置重新初始化 USB HID，最后显示状态。手动操作不受 `AUTO_TAILSCALE_ON_BOOT=0` 限制，也不会修改此开机选项。

这次操作会短暂断开并重新连接 USB；它不发送按键、不重启网页服务、不改持久唤醒锁设置。Tailscale 失败仍会独立尝试 USB 修复；各阶段结果记录在 `/data/adb/wake-bridge/action.log`，不输出 Token。USB 已处于 `suspended` 时拒绝重绑，以保留主机的唤醒链路。

## ADB 接管复合设备的原因

部分 ROM 在 ADB-only 模式使用 `18d1:4ee7`。Google USB 驱动将这个 ID 直接匹配为整个 ADB 设备。模块再追加 HID 后，Windows 仍可能让 WinUSB 接管父设备，导致没有 HID 子接口；这不是单纯的设备缓存问题。

模块现在创建 HID 接口 0、ADB 接口 1，并提供可选的 `USB_PRODUCT_ID`。默认空值保留 ROM 的 PID，不自动分配或猜测 USB 身份。

本次 Redmi 4X 和 Windows Google ADB 驱动实测使用以下本机配置：

```sh
KEEP_ADB=1
USB_PRODUCT_ID=0x4ee2
```

`4ee2` 是既有 Google USB PID，并非此项目拥有的 PID；此设置是本机兼容性验证结果，不保证适用于所有手机或驱动。该驱动将 `4ee2&MI_01` 匹配到 ADB 接口，而父设备由 `usbccgp` 管理。长期部署应采用设备厂商支持的复合配置或已分配的 USB 标识。

更换 PID 后，Linux 端按旧 VID/PID 匹配的 USB 唤醒规则需要同步更新。手机端修复完成不等于主机唤醒能力已验证。

## 实测结果（2026-11-21）

Windows 识别为：

| 设备 | 接口 | 驱动 | 错误码 |
| --- | --- | --- | --- |
| USB Composite Device | 父设备 | usbccgp | 0 |
| USB 输入设备 | MI_00 | HidUsb | 0 |
| HID Keyboard Device | MI_00 | kbdhid | 0 |
| Android Composite ADB Interface | MI_01 | WinUSB | 0 |

Tailscale 网页唤醒请求返回 `hid=ok`，未触发 USB 重绑；有线 ADB 正常，临时 TCP ADB 已关闭。

这台电脑的 `powercfg /a` 只提供 S0 现代待机和 S4 磁盘休眠。手机 HID、USB 复合设备及根集线器的 `DEVPKEY_Device_PowerData` 报告 `PD_DeepestSystemWake=PowerSystemWorking`，当前驱动路径未报告 S4 唤醒能力。S4 通常更省电，但不能把 USB 键盘识别成功视作 S4 可唤醒；固件设置或硬件变化后需要重新查询并实测。

### S0 睡眠与 HID 唤醒

单窗口复测日志（本地时间 UTC+8）：

| 时间 | 记录 |
| --- | --- |
| 12:35:24 | Windows 506，进入现代待机，原因 `SC_MONITORPOWER` |
| 12:35:53 | 手机定时调用模块 `wake.sh` |
| 12:35:54 | 手机 `hid=ok`，USB 前后均为 `configured`，没有重新绑定 |
| 12:35:54.713 | Windows 507，退出原因 `Input Keyboard`，`SleepEntered=true`，Sleep 约 30.31 秒 |

用户确认屏幕成功恢复；后续没有再次进入待机事件。临时手机测试锁已释放，TCP ADB 端口恢复为 0。

推荐从仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sleep-windows-s0.ps1
```

该脚本向自己创建的隐藏窗口发送一次 `WM_SYSCOMMAND / SC_MONITORPOWER`，由默认窗口过程请求关屏，随后等待唤醒并释放窗口；不广播给其他窗口。在支持 S0 的本机已验证进入现代待机。

此前两种测试方法的限制已查明：

- `.NET Application.SetSuspendState('Suspend', false, false)` 在本机实际进入 S4，事件 42 的 `TargetState=5 / EffectiveState=5`，不能据此判断 S0 失败。该次手机发键时 USB 为 `not attached`，最终由电源键恢复。
- PsShutdown `-x` 使用广播关屏。旧测试在 HID 触发 `Input Keyboard` 退出后 76 毫秒，又出现 `SC_MONITORPOWER` 进入事件。具体再次处理消息的窗口尚未定位；改用单窗口投递后复测消除了再次关屏。

### 功耗与验证边界

本机当前已验证 HID 可唤醒的是 S0；S4 测试未成功，S3 未由固件提供。当前端口、固件和驱动路径的结果不代表所有端口或未来配置都无法从 S4 唤醒。

本次 S0 事件的 SW/HW DRIPS 驻留均为 0，短时测试没有证明已进入最深平台空闲状态。管理员 `/requests` 当前为空，SleepStudy 两段测试均没有 top-offender 明细，因此尚无证据可归因到某个设备或进程，也不能直接给出实际待机功耗。下一步节能诊断需要更长的静置测试及详细 SleepStudy 后再针对阻塞项处理。

手机为保证 30 秒定时器运行持有临时测试唤醒锁。本次证明的是 Windows S0 的 HID 唤醒；手机完全休眠后的 Tailscale 网页全链路唤醒仍需独立验证。关屏、网页 HTTP 200、`hid=ok` 都不能单独证明主机已从睡眠恢复。
