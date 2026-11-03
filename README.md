# 随航助手 · Sidecar Assistant

**让 iPad 成为 Mac 的屏幕，连接更省事。**

为 Mac mini 等设备准备的 macOS 菜单栏工具：登录后自动连接随航，也能在 iPad 上点一下快捷指令，主动发起连接。

## ⬇️ 下载 / Download

### [直接下载 macOS App · Download for macOS](downloads/SidecarAssistant-v2.15.0-macOS.zip?raw=1)

**v2.15.0 · macOS 14.2+ · Apple 芯片与 Intel 通用版 / Universal**

下载并解压，将 `随航登录助手.app` 拖入“应用程序”即可使用，无需编译。

Unzip the download and move `随航登录助手.app` to Applications. No build required.

[下载目录 / Downloads](downloads/)

[简体中文](#简体中文) · [English](#english)

## 简体中文

### 可以做什么

- 自动发现可用 iPad，也可以指定一台设备。
- 登录后启动，或拔掉最后一块实体屏幕时，按设置自动连接。
- 在菜单栏直接连接、断开、查看状态。
- 从 App 添加 iPad 快捷指令，通过 iCloud 同步到 iPad。
- 中文、英文界面，默认跟随系统语言。

### 安全与隐私

**本地运行，源码可查。**

- App 自身仅使用 macOS 系统框架与 API，不集成第三方 SDK。
- App 自身不发起网络接口请求，不包含广告、遥测或数据上传功能。
- 设置和运行日志保存在本机，App 不读取或保存 SSH 登录密码。

随航设备发现和连接由 macOS 系统处理；可选的 SSH 快捷指令、iCloud 同步以及另行安装的 BetterDisplay 使用各自的网络服务。随航助手调用了系统私有随航接口，系统升级后的兼容性仍需核对。

### 开始前

- Mac 需要 **macOS 14.2 或更新版本**；App 同时支持 Apple 芯片和 Intel。
- Mac 和 iPad 需要符合 [Apple 随航要求](https://support.apple.com/en-us/102597)，登录同一 Apple 账户并开启双重认证。无线连接时打开 Wi-Fi、蓝牙和接力，保持设备靠近，唤醒并解锁 iPad。
- Mac 完全没有可用屏幕时，先安装适合当前系统的 [BetterDisplay](https://github.com/waydabber/BetterDisplay)，并启用一个虚拟屏幕。有内屏、实体外屏或可复用的独立虚拟屏幕时，无需启动 BetterDisplay。

### Mac 上，3 步设置好

1. **放进应用程序**：将 `随航登录助手.app` 拖到“应用程序”文件夹，然后打开。可以[直接下载 App](downloads/SidecarAssistant-v2.15.0-macOS.zip?raw=1)，或[从源码构建](#从源码构建)。
2. **选好连接方式**：不接显示器的 Mac mini，推荐下面这组设置。
3. **保存并试一次**：点击“保存设置”，再点“连接 iPad”。显示“已连接”就可以用了。

| 设置 | 推荐选择 |
| --- | --- |
| 连接设备 | 自动发现设备 |
| 登录后启动 App | 勾选 |
| 自动连接方式 | 无实体屏幕时自动连接 |

三种自动连接方式：

| 方式 | 什么时候连接 |
| --- | --- |
| 无实体屏幕时自动连接 | App 启动时没有内屏和实体外屏，或最后一块实体屏幕断开时 |
| 始终自动连接 | App 启动或最后一块实体屏幕断开时，不限制是否接着实体屏幕 |
| 禁止自动连接 | 保持待命，由你手动连接或运行快捷指令 |

想固定某台 iPad，选择“指定 iPad”→“查找 iPad”→选择设备，再保存；也可以填写完整设备名，支持中文、空格和标点。

关闭或最小化窗口后，App 会留在顶部菜单栏。点图标→“随航助手设置”可重新打开；“连接 iPad”和“断开连接”可随时手动操作。“关于随航助手”中可查看版本和作者。

设置页顶部的“语言”可以选择“跟随系统 / 简体中文 / English”，切换后立即生效、自动保存。其他连接设置修改后需要点击“保存设置”。

### iPad 上，一键连接

1. **Mac 开启远程登录**：“系统设置”→“通用”→“共享”→“远程登录”，允许你使用的 Mac 账户访问。
2. **在 App 里添加**：“更多操作”→“添加到快捷指令…”，按提示填写 Mac 主机名或 IP、登录用户名及认证信息。端口通常保留 `22`，连接脚本已经填好。
3. **同步到 iPad**：两台设备使用同一 Apple 账户，并开启“快捷指令”的 iCloud 同步。Mac 上的开关在“快捷指令”→“设置”→“通用”。[Apple 同步说明](https://support.apple.com/zh-cn/guide/shortcuts-mac/apdb3a4240b0/mac)
4. **点一下连接**：Mac 已登录桌面、两台设备在同一网络、iPad 已解锁时，运行 iPad 上的“iPad随航连接”。英文模板名为“iPad Sidecar Connect”。

快捷指令会直接尝试连接，不受自动连接方式和实体屏幕限制；自动选设备时只查找一次。没有启用 iCloud 同步，也可以把 [中文模板](Resources/Shortcuts/zh-Hans/iPad随航连接.shortcut) 或 [英文模板](Resources/Shortcuts/en/iPad%20Sidecar%20Connect.shortcut) 隔空投送到 iPad 添加。

App 根据当前语言选择新添加的模板；已添加的快捷指令不会自动变更语言。系统按钮和灰色占位文字跟随“快捷指令”App 的语言。模板不包含你的主机、用户名或密码，需要自行填写。

### 常见问题

**开机时还没发现 iPad？**

符合自动连接条件时，首次查找失败后等待 4 秒，再失败等待 6 秒，之后每 8 秒重试，总时限 2 分钟。无需自动连接时不会进入这段重试。超时后，可以手动点“连接 iPad”或运行快捷指令，再试一次。

**没装 BetterDisplay 能用吗？**

有内屏、实体外屏或可复用的独立虚拟屏幕时可以。完全没有可用屏幕时，需要先准备好 BetterDisplay 虚拟屏幕；App 负责按需启动它，不会代你创建虚拟屏幕。

**窗口关闭后去哪了？**

在 Mac 顶部菜单栏。要完全退出，点菜单中的“退出随航助手”。

**如何排查连接问题？**

先唤醒并解锁 iPad，再试一次。快捷指令报错时，检查 Mac 主机、用户名、认证信息及远程登录状态。仍有问题，可在“更多操作”→“查看运行记录”中查看详情。分享日志前请自行移除设备名称等个人信息。

**升级会丢设置吗？**

退出旧版，再替换“应用程序”里的 App 即可；原设置保留。App 文件名保持 `随航登录助手.app`，已有快捷指令无需改路径。

### 从源码构建

需要 macOS 和 Xcode Command Line Tools。在项目根目录运行：

```sh
./scripts/build.command
```

构建脚本会编译 Apple 芯片和 Intel 两个架构、运行测试并签名，产物在 `dist/随航登录助手.app`。构建过程不会启动 App 或连接真实 iPad。脚本使用本地 ad-hoc 签名，不包含 Developer ID 签名或 Apple 公证流程。

只运行测试：

```sh
./scripts/test.command
```

目录结构：

```text
Sources/App/            主程序、设置界面、语言和屏幕监听
Sources/Helpers/        随航连接与状态读取助手
Resources/Localizations/ 中文和英文文案
Resources/Shortcuts/    按语言分组的模板源码和已签名快捷指令
Tests/                  主程序及连接助手测试
Tools/                  图标生成工具
scripts/                构建和测试入口
downloads/              可直接下载的 App 发布包
docs/                   开发与维护说明
```

更多实现、配置位置和模板维护方式见 [开发说明](docs/DEVELOPMENT.md)。

## English

**Use your iPad as a Mac display with less setup each time.**

Sidecar Assistant is a macOS menu bar app for automatic and manual Sidecar connections, with an iPad shortcut to start a connection remotely.

### Security & privacy

**Runs locally, with source available for inspection.**

- The app itself uses only macOS system frameworks and APIs, with no third-party SDKs.
- The app itself makes no network API requests and includes no advertising, telemetry or data-upload features.
- Settings and logs stay on your Mac. The app does not read or store SSH login passwords.

macOS handles Sidecar discovery and connections. Optional SSH shortcuts, iCloud sync and the separately installed BetterDisplay use their own network services. The helpers use private macOS Sidecar interfaces, so compatibility should be checked after system updates.

### Quick start

1. Move `随航登录助手.app` to **Applications** and open it. [Download the app](downloads/SidecarAssistant-v2.15.0-macOS.zip?raw=1) or [build from source](#build-from-source).
2. For a Mac mini without a monitor, choose **Find a Device Automatically**, enable **Launch App at Login**, and select **Connect Only Without a Physical Display**.
3. Click **Save Settings**, then **Connect to iPad**.

Requires macOS 14.2 or later and [Sidecar-compatible devices](https://support.apple.com/en-us/102597). Sign in to the same Apple Account with two-factor authentication. For wireless use, enable Wi-Fi, Bluetooth and Handoff, and keep your iPad nearby, awake and unlocked.

If your Mac has no usable display, install [BetterDisplay](https://github.com/waydabber/BetterDisplay) and enable a virtual display first. A built-in display, physical external display or reusable independent virtual display removes the need to launch BetterDisplay. The app does not create virtual displays for you.

| Auto-connect mode | Behavior |
| --- | --- |
| Connect Only Without a Physical Display | Connect at app launch if no built-in or physical external display is present, or when the last physical display is disconnected |
| Always Connect Automatically | Connect at app launch or when the last physical display is disconnected, regardless of physical display availability |
| Never Connect Automatically | Wait for a manual connection or shortcut |

Automatic device discovery retries after 4 seconds, then 6 seconds, then every 8 seconds, with a total limit of 2 minutes. It runs only when the auto-connect conditions are met. If your iPad appears later, start another connection manually.

Use **Connect to iPad** or **Disconnect** whenever needed. Closing or minimizing the window keeps the app in the menu bar. Change **Language** at the top of Settings; the default is **System Default**, and language changes save immediately.

### Connect from your iPad

1. On your Mac, enable **System Settings → General → Sharing → Remote Login** for your Mac account.
2. In Sidecar Assistant, choose **More → Add to Shortcuts…** and enter your Mac host, login username and authentication details. Keep port `22` unless you use a different SSH port. The command is already filled in.
3. Enable Shortcuts iCloud Sync on both devices using the same Apple Account. On Mac: **Shortcuts → Settings → General → iCloud Sync**. [Apple sync guide](https://support.apple.com/zh-cn/guide/shortcuts-mac/apdb3a4240b0/mac)
4. With your Mac signed in to the desktop and both devices on the same network, unlock your iPad and run **iPad Sidecar Connect**.

The shortcut attempts a direct connection even when auto-connect is disabled or a physical display is attached. Automatic device selection searches once for a manual connection. Without iCloud Sync, AirDrop the [English shortcut](Resources/Shortcuts/en/iPad%20Sidecar%20Connect.shortcut) to your iPad.

New templates follow the app language. Existing shortcuts keep their current language; system action labels follow the Shortcuts app language. Templates contain no personal host, username or password.

For connection issues, wake and unlock your iPad, check your SSH settings, or use **More → View Activity Log**. Remove personal device details before sharing logs.

### Build from source

Requires macOS and Xcode Command Line Tools. Run from the repository root:

```sh
./scripts/build.command
```

The script builds a universal app for Apple silicon and Intel, runs tests, and applies an ad-hoc signature. Output: `dist/随航登录助手.app`. It does not launch the app or connect to a live iPad. Developer ID signing and notarization are separate release steps.

Run tests independently with `./scripts/test.command`. Tests use temporary settings and simulated devices. See [development notes](docs/DEVELOPMENT.md) for implementation and maintenance details.

## Acknowledgements / 致谢

- [BetterDisplay](https://github.com/waydabber/BetterDisplay) provides optional virtual-display support. It is installed separately and is not redistributed in this repository.
- [SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) provided a reference for command conventions and Sidecar API usage. This project maintains its own Objective-C helpers and builds them locally.
- Sidecar is provided by macOS. The helpers use private system interfaces, so macOS updates may require compatibility changes. This is an independent project, not an Apple product.

## License

[MIT](LICENSE) · Copyright © 2026 YueRuo
