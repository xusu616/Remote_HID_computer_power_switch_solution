# Remote HID Computer Power Switch Solution

[English](README.en.md)

利用**一台已 Root 的闲置安卓手机 + Tailscale + Magisk 模块**，将其通过 USB 线连接到远程 Linux 主机，作为 **Tailscale 可达的 USB HID 物理键盘（含 USB `soft_connect` 软重连兜底）**，实现远程一键唤醒处于挂起到内存（S3 / `s2idle`）状态的电脑。

> 本方案最初用于解决：**远程 Arch Linux 主机板载网口松动只能使用 USB 网卡、USB 网卡不支持 Wake-on-LAN (WoL)、且不想额外购买 IP-KVM 硬件** 的场景。  
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
  └── USB ConfigFS 复合设备 (ffs.adb + hid.usb0 引导键盘, bmAttributes=0xa0)
        │  (USB 数据线: /dev/hidg0 Left Shift + soft_connect 兜底)
        ▼
[远程 Linux / PC 主机 (S3 / s2idle 挂起)]
```

---

## 核心特性

1. **打包为标准 Magisk / KernelSU / APatch 模块**：
   * 安装后自动在开机阶段初始化 USB HID 复合设备（保留 `ffs.adb` 调试，同时挂载 `hid.usb0` 引导键盘并设置 `bmAttributes=0xa0` 远程唤醒位）。
   * 随模块提供 `/system/bin/wake-bridge` 命令行工具，升级模块保留 `/data/adb/wake-bridge/config.env` 原配置与 Token。
2. **原生 Root HTTP 监听（无需 Termux，防 Android 杀后台）**：
   * 直接使用 Magisk 自带 BusyBox `httpd` 监听 `:9876` 并申请 `/sys/power/wake_lock`；
   * **绝对不能“收到任意 Tailscale 流量就唤醒”**（Tailscale 有心跳包与 MagicDNS 探测），所有请求必须带随机生成的 24 位十六进制 `token`，且仅允许 Tailscale / 内网 IP 访问。
3. **双保险唤醒机制（`wake.sh`）**：
   * **第一招**：向 `/dev/hidg0` 发送 **Left Shift 按下并松开**（之所以不用回车/空格，是因为万一电脑本来就醒着，按 Shift 不会在终端或编辑器里误输入字符或提交命令）；写操作带 `timeout 2` 保护，防止主机未轮询端点时阻塞。
   * **第二招**：等待 2 秒后检查 `/sys/class/udc/<udc>/state`，如果主板在 S3 下仍维持 `suspended`（主线 4.19 `f_hid` 默认通常不含下游 KVM 的 `wakeup_on_write` 补丁），自动通过 `soft_connect`（`disconnect` → `connect`）触发一次 USB 软拔插，强制主板 USB 控制器响应插入唤醒。
4. **解决 Android 实机关键坑位**：
   * Android `ueventd` 默认不创建 `/dev/hidg0`：脚本自动读取 `hid.usb0/dev`（`major:minor`）并 `mknod /dev/hidg0`。
   * 规避 Android `init` 属性触发器抢先重绑 `UDC` 导致 `EBUSY` 的竞态问题。
   * 使用 `base64 -d` 写入含 `\x00` 的 63 字节 HID 描述符与按键包，避免不同 BusyBox / `mksh` 版本对 `\x00` 转义截断。
   * 在 `start-daemon.sh` 中补全 `/system/bin` 等 `PATH`，防止 Magisk `service.d` 启动阶段丢失 `ip` 等系统命令。

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
1. 前往 [GitLab Releases](https://gitlab.com/xusu616/remote_hid_computer_power_switch_solution/-/releases) 下载最新 `wake_bridge-v1.0.0.zip`（或使用 `python3 scripts/build-module.py` 本地打包）。
2. 在手机上打开 **Magisk / KernelSU / APatch** → **模块** → **从本地安装** → 刷入 ZIP。
3. 刷入日志会提示自动生成在 `/data/adb/wake-bridge/config.env` 的随机 `TOKEN`。**重启手机**生效。
4. 重启后通过 `adb shell` 或终端查看完整控制 URL：
   ```bash
   su -c "wake-bridge url"
   su -c "wake-bridge status"
   ```

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
2. 主机唤醒一次 `wake` URL 后返回 `hid=ok`（注：如果在 Windows 上同时插过同 `VID:PID` 的旧单接口 ADB，Windows 注册表缓存可能导致未轮询第二个 HID 接口；Linux 主机会实时读取描述符，不受影响）；
3. BIOS 与 Linux（`/proc/acpi/wakeup`、`power/wakeup`、`udev` 规则）允许该 USB 端口唤醒 S3 挂起。

---

## 仓库结构

```text
├── magisk-module/                   # Magisk/KernelSU/APatch 模块源码
│   ├── META-INF/com/google/android/ # 标准 Magisk 安装器入口
│   ├── system/bin/wake-bridge       # 命令行管理工具 (status/url/wake/hid/start/stop)
│   ├── wake-bridge/                 # 核心脚本与 BusyBox HTTP/CGI 服务
│   ├── customize.sh                 # 安装检查、随机 Token 生成与权限配置
│   ├── service.sh                   # 开机自启脚本
│   └── uninstall.sh                 # 卸载清理脚本
├── scripts/
│   ├── build-module.py              # 跨平台生成可刷入 ZIP（保证 LF 与 Unix 权限）
│   └── build-module.sh
└── docs/
    ├── LINUX-USB-WAKEUP.md          # Linux 端 USB 唤醒验证与 udev 持久化指南
    └── ALTERNATIVE-SOLUTIONS.md     # 其他方案对比（IP-KVM / Pi Zero 2 W / WoL / 蓝牙等）
```

---

## 其他替代方案对比

如果你的主机不支持 USB 唤醒、经常进挂起到磁盘（S4）或需要完全关机拉起，请参阅 [docs/ALTERNATIVE-SOLUTIONS.md](docs/ALTERNATIVE-SOLUTIONS.md)（包含 **NanoKVM PCIe / GL.iNet Comet**、**树莓派 Zero 2 W**、**台式机 PCIe 有线网卡 WoL**、**手指机器人**，以及**为什么不建议用手机蓝牙键盘唤醒**的原因）。

---

## 开源协议

[MIT License](LICENSE)
