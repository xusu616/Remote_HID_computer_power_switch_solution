# 电源配置与 Tailscale 开机连接

v1.0.9 将已部署 v1.0.7 的 HID/ADB 行为同步回源码，并加入开机一次的 Tailscale 连接请求和电源状态诊断。保持 `DAEMON_WAKE_LOCK=1`、`HID_WATCHDOG=1` 的项目默认值。

## 配置与升级

配置位于 `/data/adb/wake-bridge/config.env`。升级保留 Token 和已有配置；缺失的新选项补为下表默认值。首次安装的 ADB 模式沿用 v1.0.7 安装器选择，超时默认 `KEEP_ADB=0`。

| 选项 | 默认值 | 行为 |
| --- | --- | --- |
| `AUTO_TAILSCALE_ON_BOOT` | `1` | 开机阶段执行一次 Tailscale 服务检查/连接请求 |
| `DAEMON_WAKE_LOCK` | `1` | HTTP 服务持有 `wake_bridge_daemon`，阻止系统 suspend |
| `HID_WATCHDOG` | `1` | 保留约每2秒检查的 HID 自恢复进程 |
| `KEEP_ADB` | `0` | 0为纯HID/关闭ADB；1为复合USB HID+有线及无线ADB；2为纯USB HID+无线ADB |

`DAEMON_WAKE_LOCK=0` 仅允许系统空闲时自行 suspend；`HID_WATCHDOG=0` 可停用主动周期检查。修改这两个选项后重启守护服务。允许 suspend 不等于强制 Doze，也不代表 CPU 一定真正进入系统 suspend 或 Tailscale 一定长期在线。

管理命令未被 KernelSU 挂载时，可使用绝对路径 `/data/adb/modules/wake_bridge/system/bin/wake-bridge`。`status` 显示状态而不打印 Token；显式 `url` 才显示带 Token 的控制地址。

## Tailscale 一次启动流程

1. 等待 Android `sys.boot_completed=1` 和现有10秒初始化等待，初始化 HID/HTTP。
2. 检查 user 0 的 `com.tailscale.ipn` 已安装，并检查准确的 `IPNService` ServiceRecord 及其 `isForeground=true`。App/GUI 进程存在不等于该服务已运行。
3. 已有前台服务则跳过；否则发送：

   ```sh
   am broadcast --user 0 --include-stopped-packages -a com.tailscale.ipn.CONNECT_VPN -n com.tailscale.ipn/.IPNReceiver
   ```

4. 为异步初始化固定等待10秒一次，随后复核服务。没有 VPN 重试或持续轮询，也不会因 HTTP 服务 restart 而自动重复开机动作。

服务前台状态不证明尾网可达，仍需从另一台 Tailscale 设备请求状态/唤醒接口。未安装、广播失败、检查失败或服务未确认会记录到 `/data/adb/wake-bridge/tailscale-start.log`；`tailscale_last_start_result` 是最近一次启动动作的缓存结果，不能代替当前连接探测。

未登录、未同意 VPN 权限、FBE 用户尚未解锁时，可能需要人工处理。模块不自动登录、不打开 GUI 作为兜底，也不更改系统 always-on、lockdown、Wi-Fi、电池优化或 Doze。

手动执行一次启动动作：

```sh
/data/adb/modules/wake_bridge/wake-bridge/start-tailscale.sh
```

## 实测与边界（2026-11-21）

已在 Android Tailscale 1.104.6 上验证 helper：已有前台服务时跳过，force-stop 后显式请求恢复 `IPNService` 和 `tun1`。外层开机日志重定向条件下仍可启动；Windows 与 Arch 的 Tailscale HTTP 请求均返回200（本次分别约1.457秒和0.842秒）。

这些结果验证 helper 冷启动和远程 HTTP 可达。本次未重新进行完整手机重启回归；不能据此宣称全部开机/FBE场景已验证。

早期空闲实验 `suspend_success=0`，当时 Windows HID 写入测试失败。随后已修复 Windows ADB/HID 驱动绑定，并于同日完成 S0 HID 唤醒验证，详见 [Windows HID 识别与唤醒](WINDOWS-HID.md)。后续手机离线静置后也观察到 suspend success 计数增加，但尚未验证手机完全休眠后的 Tailscale 网页唤醒全链路，也不能据此宣称 Windows S3 或最深 DRIPS 唤醒已验证。项目默认持续锁和 watchdog 保持1；实验手机已有显式0配置属于该设备的测试设置，不能同步成项目默认值。

状态包含活动锁、`/proc/uptime`，以及可读时的 suspend success/fail 计数。USB UDC 的 `suspended` 仅表示 USB 链路状态。HTTP 请求会唤醒手机处理请求，休眠判断应比较空闲前后的内核计数；不要以关屏、低频或存在 `tun` 接口代替实际 suspend/远程可达验证。

## 维护要求

`am` 的输出须先由命令替换捕获，再由 root shell 追加日志。直接把 `/data/adb` 日志文件作为 Binder 命令的输出 FD 会交给 Android 系统服务，本次实机 SELinux 已拒绝该访问并造成事务失败。不要重新引入该重定向。

保持已部署 v1.0.7 的安全停止进程筛选、唤醒串行化、直接受超时控制的 HID 写入、挂起状态避免 UDC 重绑及 `KEEP_ADB=0/1/2` 行为。启动的一次1秒 `kill -0` 检查用于发现立即退出，不保证 socket 已监听；HTTP 请求才验证真正服务可达。
