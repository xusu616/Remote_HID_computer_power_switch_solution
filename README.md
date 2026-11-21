# Remote HID Computer Power Switch Solution

[English](README.en.md)

利用**一台已 Root 的闲置安卓手机 + Tailscale + Magisk 模块**，将其通过 USB 线连接到远程 Linux 主机，作为 **Tailscale 可达的 USB HID 物理键盘**，实现远程一键唤醒处于挂起到内存（S3 / `s2idle`）状态的电脑。

> 本方案最初用于解决：**远程 Arch Linux 主机板载网口松动只能使用 USB 网卡、USB 网卡不支持 Wake-on-LAN (WoL)、且不想额外购买 IP-KVM 硬件** 的场景。\
> 已在 **Redmi 4X (`santoni`) · LineageOS 18.1 · Linux 4.19.325 · Magisk + ACC** 环境实机验证通过。

---

## 为什么常规方式唤不醒休眠中的电脑？

当 Linux 进入**挂起到内存（Suspend to RAM，S3 / `s2idle`）**后，CPU 与操作系统完全冻结：
* 电脑上的 **Tailscale、SSH、USB 共享网络、ADB/MTP 服务端**全部停止运行；
* 此时主板仅保留少数**硬件唤醒源**（电源键、PCIe 原生网卡 WoL 魔术包、USB 键鼠的 `Remote Wakeup` 信号、USB 控制器插入电平变化）。
* 因此如果用一台通过 Wi-Fi / 蜂窝网络常驻在线的 Root 安卓机插在电脑 USB 口上，就能充当“**跨 Tailscale 的远程物理手指**”。

```text
[你的远程手机 / 笔记本]
        │  (Tailscale 加密组网: 100.x.y.z)
        ▼
[常驻 Root 安卓手机 (Magisk wake_bridge 模块)]
  ├── Android Tailscale App (保持组网在线)
  ├── BusyBox httpd :9876   (原生 root 守护进程 + Token 鉴权，防误触发)
  ├── ACC Magisk 模块       (控制 40%~60% 充电防鼓包)
  └── USB ConfigFS HID (hid.usb0 引导键盘 + 可选 ffs.adb, bmAttributes=0xa0)
        │  (USB 数据线: /dev/hidg0 Left Shift + 受控 HID 恢复)
        ▼
[远程 Linux / PC 主机 (S3 / s2idle 挂起)]
```

---

## 核心特性

1. **打包为标准 Magisk / KernelSU / APatch 模块**：
   * 安装后自动在开机阶段初始化 USB HID 复合设备（由 `KEEP_ADB=0/1/2` 选择纯 HID、复合 ADB 或无线 ADB 模式，并设置 `bmAttributes=0xa0` 远程唤醒位）。
   * 模块内提供 `/data/adb/modules/wake_bridge/system/bin/wake-bridge` 命令行工具，升级模块保留 `/data/adb/wake-bridge/config.env` 原配置与 Token。
2. **原生 Root HTTP 监听（无需 Termux，防 Android 杀后台）**：
   * 使用 Root 框架提供的 BusyBox `httpd` 监听 `:9876`，默认 `DAEMON_WAKE_LOCK=1` 持有持续唤醒锁；`HID_WATCHDOG=1` 保留 HID 自恢复。可配置空闲 suspend，但需实机验证，详见 [电源与 Tailscale 配置](docs/POWER-AND-TAILSCALE.md)。
   * **绝对不能“收到任意 Tailscale 流量就唤醒”**（Tailscale 有心跳包与 MagicDNS 探测），所有请求必须带随机生成的 24 位十六进制 `token`，且仅允许 Tailscale / 内网 IP 访问。
3. **串行唤醒与挂起链路保护（`wake.sh`）**：
   * 向 `/dev/hidg0` 发送 **Left Shift 按下并松开**，避免给已经醒着的电脑误输入字符；每次写入带 `timeout 2`，并串行处理并发请求。
   * 主机 USB 处于 `suspended` 时保留 UDC 连接并发送 HID 唤醒报告，等待主机恢复；不会通过软拔插破坏挂起链路。仅在已恢复到 `configured` 且 HID 写入仍失败时执行受控恢复。
4. **解决 Android 实机关键坑位**：
   * Android `ueventd` 默认不创建 `/dev/hidg0`：脚本自动读取 `hid.usb0/dev`（`major:minor`）并 `mknod /dev/hidg0`。
   * 规避 Android `init` 属性触发器抢先重绑 `UDC` 导致 `EBUSY` 的竞态问题。
   * HID 描述符使用 `base64 -d`；固定按键报告使用 shell 内置 `printf` 并直接受超时控制，避免遗留阻塞写入进程。
   * 在 `start-daemon.sh` 中补全 `/system/bin` 等 `PATH`，防止 Magisk `service.d` 启动阶段丢失 `ip` 等系统命令。

5. **开机一次启动 Tailscale**：
   * 默认 `AUTO_TAILSCALE_ON_BOOT=1`。真正的前台 `IPNService` 已运行时跳过；未运行时发送官方 `CONNECT_VPN` 显式广播，等待10秒一次复查。
   * 不自动登录或替用户同意 VPN 权限，也不持续轮询 VPN；结果写入日志并显示于状态接口。详见 [启动流程与验证边界](docs/POWER-AND-TAILSCALE.md)。

---

## 前置检查：手机内核是否支持 USB HID Gadget？

在手机 Root Shell 下检查（多数 4.19+ 第三方/LineageOS 内核已默认开启）：

```bash
su -c 'zcat /proc/config.gz 2>/dev/null | grep -E "CONFIG_USB_CONFIGFS|CONFIG_USB_F_HID"'
```

看到 `CONFIG_USB_F_HID=y` 或 `CONFIG_USB_CONFIGFS_F_HID=y`（`=m` 也可）即可直接使用，**无需重编内核**。

---

## 安装与使用

### 1. 下载并刷入 Magisk 模块
1. 使用 `python3 scripts/build-module.py` 本地打包当前 `wake_bridge-v1.0.11.zip`；已发布的安装包可从 [GitLab Releases](https://gitlab.com/xusu616/remote_hid_computer_power_switch_solution/-/releases) 下载，以发布页实际版本为准。
2. 在手机上打开 **Magisk / KernelSU / APatch** → **模块** → **从本地安装** → 刷入 ZIP。
3. 安装器将随机 `TOKEN` 保存在 `/data/adb/wake-bridge/config.env`，升级保留 Token；安装日志和 `status` 不直接输出 Token，显式 `url` 命令可查看完整控制 URL。**重启手机**使开机脚本生效。
4. 重启后，在电脑终端（PowerShell / CMD）使用完整路径查看控制 URL 和状态：

   ```powershell
   adb shell su -c "/data/adb/modules/wake_bridge/system/bin/wake-bridge url"
   adb shell su -c "/data/adb/modules/wake_bridge/system/bin/wake-bridge status"
   ```

   如果已经通过 `adb shell` 和 `su` 进入手机 root shell（提示符为 `#`），直接执行：

   ```sh
   /data/adb/modules/wake_bridge/system/bin/wake-bridge url
   /data/adb/modules/wake_bridge/system/bin/wake-bridge status
   ```

   > 短命令 `wake-bridge` 依赖系统命令路径中存在该脚本，`/system/bin/wake-bridge` 需要模块系统挂载生效。若提示 `inaccessible or not found`，使用上述模块完整路径。

### 模块 Action：手动启动 Tailscale 并修复 ADB/HID

在 Magisk / KernelSU / APatch 的模块页面点击 **Action / 操作**，执行一次 Tailscale 启动检查，然后根据现有 `KEEP_ADB` 配置修复 USB ADB/HID，最后显示状态。Action 使用手动模式，所以即使 `AUTO_TAILSCALE_ON_BOOT=0`，此次点击仍会请求 Tailscale 连接；不会修改开机选项或已有登录状态。

Tailscale 启动失败时仍会继续独立的 ADB/HID 修复，并明确显示各阶段结果。失败日志保留在 `/data/adb/wake-bridge/action.log`；状态及日志不输出 Token。

如果主机 USB 链路为 `suspended`，Action 会跳过修复并提示先手动唤醒主机，或物理拔插 USB 后重试，保持挂起中的 USB 连接。Action 不发送 HID 按键，不更改 CPU/电源模式，也不自动让电脑睡眠。使用有线 ADB 时修复可能重新枚举 USB，调试连接会暂时中断。

“无法读取 USB 控制器状态”表示状态节点读取失败，应检查 UDC 配置、节点和 root 权限。未插 USB 线通常仍能读取 `not attached`，因此该错误不直接表示数据线没接好。修复脚本在等待 Android ADB 初始化后、实际解绑 USB 前会再次检查挂起状态。

### 2. 手机端防失联与电池保护设置（必做）
1. **安装并登录 Tailscale Android App**：连上远程位置的 Wi-Fi。
2. **后台保活**：系统设置中将 Tailscale 电池优化设为 **无限制 / 不优化**，在多任务界面加锁，App 内开启开机自启 / Always-on。
3. **取消锁屏密码（重要）**：开启文件加密（FBE）的手机如果意外重启停在解锁界面，Wi-Fi、Tailscale 与自启脚本均不会完全就绪；用作远程跳板的旧机建议取消 PIN/图案锁屏。
4. **使用 ACC 模块限制 40%~60% 充电防鼓包**：
   > 本模块**不再内置**简易充电守护脚本，建议直接安装官方 **ACC (Advanced Charging Controller)** Magisk 模块由专业守护进程 `accd` 接管：
   ```bash
   # 将充电上限设为 60%、下限设为 40%
   su -c "acc 60 40"
   # 验证配置
   su -c "acc -sp cap"
   ```
   *(若测试 `acc -t` 发现机型支持 Idle Mode 旁路供电，60% 以上可直接走 USB 供电而不耗电池。)*

### 3. 远程触发唤醒与状态查询
在加入同一个 Tailscale 网络的任意设备浏览器、快捷指令或终端中访问：

* **只查状态（不触发唤醒）**：
  ```text
  http://<手机的Tailscale_IP>:9876/cgi-bin/status?token=<你的TOKEN>
  ```
* **触发唤醒电脑**：
  ```text
  http://<手机的Tailscale_IP>:9876/cgi-bin/wake?token=<你的TOKEN>
  ```

---

## 目标 Linux 电脑端配置与验证

将手机通过 USB 数据线插到目标 Arch / Linux 主机后，请按 [docs/LINUX-USB-WAKEUP.md](docs/LINUX-USB-WAKEUP.md) 确认：
1. `lsusb` / `dmesg | grep -i hid` 能看到手机模拟的 USB 键盘；
2. 主机唤醒一次 `wake` URL 后返回 `hid=ok`，并确认主机实际恢复；Windows 上父设备被 ADB 驱动接管时，HID 子接口可能无法出现，详见 [Windows HID 识别与唤醒](docs/WINDOWS-HID.md)；
3. BIOS 与 Linux（`/proc/acpi/wakeup`、`power/wakeup`、`udev` 规则）允许该 USB 端口唤醒 S3 挂起。

---

## 仓库结构

```text
├── magisk-module/                   # Magisk/KernelSU/APatch 模块源码
│   ├── META-INF/com/google/android/ # 标准 Magisk 安装器入口
│   ├── system/bin/wake-bridge       # 命令行管理工具 (status/url/wake/hid/adb/start/stop)
│   ├── wake-bridge/                 # 核心脚本与 BusyBox HTTP/CGI 服务
│   ├── customize.sh                 # 安装检查、随机 Token 生成与权限配置
│   ├── service.sh                   # 开机自启脚本
│   ├── action.sh                    # 手动启动 Tailscale 并修复 ADB/HID
│   └── uninstall.sh                 # 卸载清理脚本
├── scripts/
│   ├── build-module.py              # 跨平台生成可刷入 ZIP（保证 LF 与 Unix 权限）
│   └── build-module.sh
└── docs/
    ├── POWER-AND-TAILSCALE.md       # 开机 VPN、功耗配置和验证边界
    ├── LINUX-USB-WAKEUP.md          # Linux 端 USB 唤醒验证与 udev 持久化指南
    └── ALTERNATIVE-SOLUTIONS.md     # 其他方案对比（IP-KVM / Pi Zero 2 W / WoL / 蓝牙等）
```

---

## Windows S0 现代待机

2026-11-21 在本机 MECHREVO JIAOLONG 上实测：手机 HID 正常识别，进入 S0 后约 30 秒发键，Windows 事件 507 记录 `Input Keyboard`，且单窗口复测没有再次关屏。

可在仓库根目录执行以下脚本进入 S0；运行后会立即关屏：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sleep-windows-s0.ps1
```

本机没有 S3；本次 S4 测试中 USB 断开，HID 未唤醒电脑。已验证可用的是 S0，但短时测试的 DRIPS 驻留仍为 0，尚未验证深度低功耗下的功耗或唤醒。本次手机使用临时定时唤醒锁发键，不证明手机完全休眠后仍可通过 Tailscale 网页触发。驱动配置、测试方法和限制详见 [Windows HID 识别与唤醒](docs/WINDOWS-HID.md)。

## 其他替代方案对比

如果你的主机不支持 USB 唤醒、经常进挂起到磁盘（S4）或需要完全关机拉起，请参阅 [docs/ALTERNATIVE-SOLUTIONS.md](docs/ALTERNATIVE-SOLUTIONS.md)（包含 **NanoKVM PCIe / GL.iNet Comet**、**树莓派 Zero 2 W**、**台式机 PCIe 有线网卡 WoL**、**手指机器人**，以及**为什么不建议用手机蓝牙键盘唤醒**的原因）。

---

## 开源协议

[MIT License](LICENSE)
