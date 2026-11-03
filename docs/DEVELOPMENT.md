# 开发与维护

面向维护者；安装与日常使用见根目录 [README](../README.md)。当前 App 版本保存在 [Info.plist](../Resources/Info.plist) 中，整理目录不改变版本号、Bundle ID 或用户设置位置。

## 构建入口

```sh
./scripts/build.command
./scripts/test.command
```

`build.command` 使用系统编译器分别构建 `arm64` 和 `x86_64`，合并三个通用可执行文件、生成图标、复制本地化资源，执行测试及本地签名校验后，将 App 输出到 `dist/`。构建不下载依赖、不运行 App，不访问真实随航设备。`test.command` 可独立运行，用临时 bundle 验证语言资源和签名模板。

这是直接使用 Clang 的 Objective-C 项目，没有 Xcode 工程、包管理器依赖或构建时下载步骤。部分 `.m` 文件是由主程序或测试入口直接导入的实现单元，不要再次作为独立编译单元加入同一个 target。

本地签名为 ad-hoc 签名。公开发行若需 Developer ID 签名或 Apple 公证，由发布者使用自己的证书完成；仓库不保存证书、账号或公证凭证。

## 模块

| 路径 | 职责 |
| --- | --- |
| `Sources/App/HeadlessSidecarLogin.m` | 配置、屏幕分类、受限进程调用、连接流程、重试和命令行入口 |
| `Sources/App/SettingsUI.m` | 设置窗口、菜单栏、登录项、快捷指令添加入口与关于弹窗 |
| `Sources/App/SettingsLayout.m` | AppKit 布局、系统配色及弱引用文案绑定 |
| `Sources/App/Localization.m` | 系统语言解析、界面语言偏好与资源查找 |
| `Sources/App/PhysicalDisplayMonitor.m` | 系统屏幕事件、去抖及最后一块实体屏幕移除检测 |
| `Sources/Helpers/SidecarLauncher.m` | 可用设备列表、连接和断开 |
| `Sources/Helpers/SidecarStatus.m` | 只读查询当前随航连接状态 |
| `Tools/MakeIcon.m` | 本地绘制 App 图标 |

## 连接规则

自动连接入口包括 App 启动、最后一块实体屏幕断开和“执行自动连接”。它们先检查已保存的自动连接规则，再决定是否查询设备。默认无屏模式下，内屏或实体外屏都会阻止自动连接；异常屏幕报告不当作无屏。

设备选择可以指定完整名称，或从系统返回的可用设备中选择第一台；自动选择时优先沿用当前已连接设备。完整设备名称保留中文、空格和标点，连接助手收到独立参数，名称不经过 Shell。

只有已进入自动连接流程，才会进行有限发现重试：首次未发现后等待 4 秒，之后 6 秒，再之后每次 8 秒，总时限 120 秒，最多 16 次尝试。等待和查询共享总预算。停止查找、连接设置改变或无屏模式接回实体屏幕时终止。超时后不持续监听 iPad 上线。

“连接 iPad”和 `--connect` 不受自动连接方式和实体屏幕限制；自动选设备时只查找一次。直接连接仍会检查是否需要 BetterDisplay，并沿用固定的启动和等待逻辑。本次目录整理不改变 BetterDisplay 的行为。

屏幕变化使用 AppKit 通知和一次性 1 秒去抖，没有周期轮询。状态在菜单打开、窗口前置、手动刷新及操作结束等事件上更新。

## 本地数据与并发

| 数据 | 位置 |
| --- | --- |
| 连接设置 | `~/Library/Application Support/HeadlessSidecarLogin/config.json` |
| 运行记录 | `~/Library/Logs/HeadlessSidecarLogin/run.log` |
| 语言偏好 | `local.HeadlessSidecarLogin` 用户偏好域中的 `AppLanguage` |

Bundle ID 保持 `local.HeadlessSidecarLogin`，实际 App 文件名保持 `随航登录助手.app`，以兼容既有设置和 SSH 快捷指令。

关于弹窗可通过 `Resources/Info.plist` 的 `YueRuoWebsiteURL` 配置作者链接，只展示有效的 HTTPS 地址；未配置时不显示链接。

配置限制 64 KiB，按白名单验证类型和选项；写入使用临时文件和替换。锁文件、日志及配置使用当前用户权限和文件类型检查。`instance.lock` 限制 GUI 单实例，`run.lock` 串行化连接和检查。进程调用使用固定可执行文件和独立参数，并限制超时及捕获输出大小。

App 不新增网络监听或账号服务；不保存 SSH 密码，不修改远程登录或 iCloud 设置。SSH 认证由系统和快捷指令管理。运行记录可能包含设备名称，提交问题时应脱敏。

## 双语资源

`Resources/Localizations/zh-Hans.lproj/` 与 `en.lproj/` 使用相同文案键。英文翻译必须保留原格式参数的数量、顺序和类型，测试会核对。

`AppLanguage` 只允许 `system`、`zh-Hans` 和 `en`。默认按系统首个支持的语言选择；中文地区及繁体中文偏好使用简体中文界面；没有支持的语言时回退到英文。语言不写入连接配置，不改变设备名、自动连接规则或未保存输入。

## 快捷指令

中英文模板采用一致结构：

```text
Resources/Shortcuts/
├── zh-Hans/
│   ├── Template.plist
│   └── iPad随航连接.shortcut
└── en/
    ├── Template.plist
    └── iPad Sidecar Connect.shortcut
```

`Template.plist` 是可编辑的未签名内容；`.shortcut` 是 App 实际使用的已签名资源。修改模板后需要使用 macOS `shortcuts sign --mode anyone` 重新签名，再替换对应 `.shortcut`。普通 App 构建不会重新签名模板，也不访问用户的快捷指令库。

模板只包含说明和标准 SSH 动作；主机、用户名和密码保持为空，默认端口为 22。固定命令：

```sh
"/Applications/随航登录助手.app/Contents/MacOS/HeadlessSidecarLogin" --connect
```

如果改变实际 App 文件名或命令行入口，需要同步维护两种模板并重新签名。不要将填好个人连接信息的快捷指令提交到仓库。

App 按当前语言选择对应签名资源，交给固定的系统“快捷指令”应用展示添加页面；打开成功不代表添加或 iCloud 同步已经完成。已添加快捷指令不会自动跟随 App 语言改变。

## 命令行

| 参数 | 行为 |
| --- | --- |
| 无参数 | 启动菜单栏 App，执行符合条件的启动逻辑 |
| `--settings` | 打开设置窗口 |
| `--check` | 只读输出屏幕分类和配置相关状态 |
| `--status` | 只读输出连接状态 |
| `--run` | 按已保存的自动连接规则运行，可能跳过 |
| `--connect` | 直接尝试连接，忽略自动连接开关和实体屏幕跳过规则 |

连接助手内部只接受 `devices`、`connect <完整设备名>`、`disconnect <完整设备名>`。退出码：0 成功，1 输入无效，2 无可用设备，3 未发现指定设备，4 接口错误，5 超时。

## 私有接口与验证范围

助手固定加载系统 `SidecarCore.framework`，通过 Objective-C runtime 核对接口类型后调用。没有自行实现随航传输协议，也没有打包系统框架或旧的第三方预编译助手。私有接口可能随系统版本变化，需要在目标 macOS 上验证。

测试覆盖屏幕分类、模式选择、有限重试、单实例和操作锁、输入校验、独立参数、语言资源，以及模拟连接助手的同步、异步、异常、重复和迟到回调。独立测试使用临时配置和模拟设备，不连接或断开真实 iPad，不修改真实登录项或快捷指令库。

测试通过不等于目标 Mac mini 的无屏开机、真实随航连接或跨设备 iCloud 同步已经验证；这些需要发布者在目标设备上确认。历史个人设备记录、运行日志和本机验证输出不作为仓库内容维护。

## 发布

源码仓库保留 `Sources`、`Resources`、`Tests`、`Tools`、`scripts`、`downloads`、文档和许可证。已签名 `.shortcut` 是必要运行资源，随源码保留；生成的 App、临时 ZIP、日志、本机配置和第三方安装包不进入源码仓库。

当前使用仓库内相对链接下载：将确认可公开的 App 发布包放到 `downloads/`，命名为 `SidecarAssistant-版本号-macOS.zip`，并同步更新 README 顶部和中英文教程中的版本及下载链接。链接末尾的 `?raw=1` 用于在 GitHub 上直接下载文件。

构建目录 `dist/` 和普通 ZIP 默认被 Git 忽略，只有 `downloads/SidecarAssistant-*-macOS.zip` 发布包被允许加入仓库。上传前核对版本号、双架构和签名，并确认快捷指令中没有填写个人信息。
