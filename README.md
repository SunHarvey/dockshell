<p align="center">
  <img src="Packaging/Branding/DockShellMark.png" width="96" height="96" alt="DockShell logo">
</p>

<h1 align="center">DockShell</h1>

<p align="center">为 macOS 打造的原生 SSH 终端客户端</p>
<p align="center">多标签 · 左右并列 / 上下堆叠分屏 · SFTP 文件传输 · 本机 Shell</p>

DockShell 使用 Swift、SwiftUI 和 AppKit 构建，让已保存的 SSH 会话、终端标签与分屏工作区集中在一个窗口中。终端模拟采用 SwiftTerm，SSH 连接通过系统 OpenSSH 与独立协议层适配。

**当前源码版本：0.1.2 / build 18，早期开发版本。** 已发布安装包从最新 Release 下载；私钥粘贴与输入显示切换以包含这些改动的构建为准。当前安装包采用 ad-hoc 签名，尚未获得 Developer ID 签名和 Apple 公证。

公开 Release 仍为 **v0.1.2**。当前源码继续加入 **M9.2：SFTP 文件上传与下载**；本轮按要求不发布 Release，体验新功能请运行当前源码或使用包含本轮提交的 CI 构建。

[功能介绍](#功能介绍) · [界面预览](#界面预览) · [安装与启动](#安装与启动) · [使用指南](#使用指南) · [开发与验证](#开发与验证)

## 功能介绍

| 功能 | 当前支持 |
|---|---|
| 会话管理 | 新建、编辑、删除、分组和搜索，双击已保存会话即可连接 |
| SSH 认证 | 密码、文件或粘贴私钥及本机 ssh-agent |
| 终端工作区 | 多标签、从 1 开始的编号、拖动排序、独立关闭 |
| 左右并列 / 上下堆叠 | 将全部已打开连接平均排成一行或一列，保留原连接和终端内容 |
| 终端显示 | 256 色、TrueColor、鼠标、窗口尺寸同步，中文与 emoji 显示 |
| 本机终端 | 当前用户的默认交互式登录 Shell，从用户主目录启动 |
| SFTP 目录浏览 | 终端右侧可收起的文件面板，每标签独立目录，支持路径导航、搜索、隐藏项及文件信息 |
| SFTP 文件传输 | 普通文件多选上传下载、串行队列、进度与取消；上传同名覆盖，下载自动编号 |
| 连接恢复 | 连接状态、协议心跳、断线提示与手动重连 |
| 主机信任 | 首次连接确认 SHA-256 指纹，保存主机记录，主机密钥变化时停止连接 |
| 凭据存储 | 会话配置存入 SQLite；密码和口令存入 Keychain，粘贴私钥由应用管理为受限文件 |
| 个性化 | 字体、字号、三套终端主题，可调整的滚屏历史 |
| 本地化 | 简体中文与英文 |

## 界面预览

以下截图来自应用工作区的真实渲染，使用演示会话与示例终端输出；工具栏已进一步精简，以当前构建为准。

### 多标签工作区

会话集中在侧栏；标签显示编号、连接状态和会话名称，可拖动排序。

![DockShell 多标签终端工作区](Docs/Images/terminal-tabs.png)

### 左右并列分屏

将已打开的连接并排显示，各终端平均分配宽度；也可切换为上下堆叠布局。

![DockShell 左右并列工作区](Docs/Images/terminal-split.png)

## 安装与启动

### 从 DMG 安装

打开 [最新版本 Release](https://github.com/SunHarvey/dockshell/releases/latest)，在 **Assets** 中直接下载 `.dmg` 安装包，无需进入 Actions 或解压 ZIP。已发布版本与构建号以该页面及安装包清单为准。

打开 DMG 后，安装窗口左侧为 **DockShell.app**，右侧为 **Applications（应用程序）**，中间箭头指引拖动方向。将应用拖到右侧，复制完成后推出磁盘映像。安装窗口使用 DockShell 当前品牌图标与海军蓝、象牙白配色，并提供中英文安装提示。

`0.1.1 / build 17` 修复 DMG 下载到其他 Mac 后背景变白的问题，并将安装盘辅助文件的图标移出初始安装画布。历史 `v0.1.0` 与各预览版本的标签和附件均保留。

当前 DMG 为 Apple Silicon / arm64 的未公证早期版本。GitHub 的 **Latest** 表示当前版本下载入口，不代表已完成 Apple 公证或全部平台验收。

Release 的 DMG 附件不会随 Actions Artifact 的保留期到期。需要测试尚未发布的提交时，也可从成功的 [CI 运行](https://github.com/SunHarvey/dockshell/actions/workflows/ci.yml)底部 **Artifacts** 直接下载 DMG；该临时下载保留 7 天。安装只需 DMG，日志和元数据包不是必需文件。

### 环境要求

- **运行目标：macOS 14 或更高版本。** 当前主要在 Apple Silicon 上验证；macOS 14 实机与 Intel 运行仍待验收。
- **构建工具：Swift 6 工具链与 macOS SDK。** 当前已验证 Swift 6.4、SDK 27.0 的 Command Line Tools 环境。
- **首次构建需要网络**，用于 Swift Package Manager 下载锁定的依赖。

可使用 Command Line Tools 构建，**无需安装完整 Xcode，也无需登录 Apple Account**。如果尚未安装命令行工具，先执行：

```sh
xcode-select --install
```

确认 `xcrun swift --version` 显示 Swift 6；较旧的系统命令行工具可能需要更新。

### 从源码运行

```sh
git clone https://github.com/SunHarvey/dockshell.git
cd dockshell

sh Scripts/check-environment.sh
sh Scripts/run.sh zh-Hans
```

运行脚本会编译项目、生成双语资源、组装 `.app`、进行本地临时签名并启动应用。生成的应用位于 `Build/debug/DockShell.app`。

英文界面或跟随系统语言：

```sh
sh Scripts/run.sh en
sh Scripts/run.sh
```

重新构建或更换语言前，请先用 **⌘Q** 退出已运行的 DockShell。语言参数只影响本次启动。

### 只构建应用

```sh
sh Scripts/build.sh
open Build/debug/DockShell.app
```

需要 Release 构建时：

```sh
sh Scripts/build.sh release
open Build/release/DockShell.app
```

请启动打包后的 `.app`。构建脚本负责组装终端与本地化资源，直接 `swift run DockShell` 不完成这一步。

## 使用指南

### 连接服务器

1. 点击工具栏 **＋ → 新建会话**，填写名称、主机、端口、用户名和认证方式。
2. 保存后双击侧栏会话，或选中会话后使用 **＋ → 在新标签中连接** / **⌘T**。
3. 首次连接时，独立核对服务器的 **SHA-256 主机指纹**，确认后继续认证。
4. 需要保存密码时，在编辑会话中勾选保存到钥匙串；连接时临时输入的密码或口令不会自动保存。

选择私钥认证后，可以使用 **选择文件** 或 **粘贴私钥**。选择文件仅引用原文件；粘贴内容在点击保存时才导入为 DockShell 管理的文件，仅当前用户可读。私钥口令仍单独保存在 Keychain，数据库不保存私钥正文。支持已识别的 OpenSSH 私钥和部分 PEM 封装；PuTTY `.ppk` 需要先转换为 OpenSSH。

密码和私钥口令输入框默认隐藏，点击眼睛图标可显示或隐藏本次输入。编辑已有会话时，按钮不会取出已保存的 Keychain 内容。托管私钥的位置、清理时机及验证方法见 [会话认证输入](Docs/会话认证输入.md)；完整格式范围见 [私钥与 ssh-agent 说明](Docs/M5/私钥Agent与连接恢复.md)。

ssh-agent 认证复用当前用户已有的 agent，密钥需事先加载；DockShell 不会自动载入或解锁 agent 中的密钥。

### 工具栏与分组

右上角保留四个入口：**＋**（新建会话、连接选中会话、本机终端）、**远程文件**、**终端布局**和 **⋯ 更多操作**（设置与当前连接操作）。悬停图标可查看用途，新建菜单提示中包含 **⌘N**、**⌘T**，这两个快捷键也列在系统菜单栏的“会话”菜单中；展开远程文件或启用分屏时，对应按钮显示选中状态。标签上的圆点继续表示各自连接状态，更多菜单内可查看当前连接详情。

分组管理位于左侧“分组”标题右侧，可新建、重命名或删除分组；下方全宽选择器用于切换会话范围。

### 管理标签与分屏

- 每个标签对应一条独立连接，同一已保存会话可以打开多个标签。
- 拖动标签调整顺序，编号会按当前顺序重新从 1 排列；点击 **×** 只关闭对应连接。
- 打开至少两个连接后，在工具栏 **终端布局** 中选择 **左右并列** 或 **上下堆叠**。
- 分屏使用全部已打开连接，不会额外创建连接。三个连接就是等宽的三列或等高的三行。
- 点击目标终端或标签切换输入焦点，选择 **标签视图** 可返回普通标签切换。
- 断线后可通过右上角 **⋯ 更多操作 → 重新连接** 手动重连。

### 浏览 SFTP 目录

打开远程标签后，点击工具栏文件夹按钮，在终端右侧展开当前标签的 SFTP 面板。双击目录进入，使用上级、主目录、刷新按钮导航，或在路径栏输入路径后按 Enter。可按名称过滤、显示隐藏项目，查看名称、大小与修改时间；窄面板中悬停名称可查看完整文件信息。

每个标签首次展开时才建立独立文件连接；隐藏再展开保留目录和连接，关闭标签会清理终端与文件连接。未保存的密码或私钥口令可能在文件面板单独请求，仍只在应用内输入。目录导航说明见 [SFTP 目录浏览](Docs/M9/SFTP目录浏览.md)。

### 上传与下载文件

浏览到远程目标目录后，点击 **上传** 可选择多个本机普通文件，同名远程文件直接覆盖。下载时先在远程列表多选普通文件，再点击 **下载** 选择本机目标目录；已有文件会保留，新下载自动保存为 `文件名 (1).扩展名`、`文件名 (2).扩展名` 等。任务会依次处理，显示进度与实际保存位置。服务器缺少安全替换能力时，同名上传会明确报错并保留原文件。

传输使用独立连接，未保存的密码可能需要再次输入。取消或失败后，剩余队列暂停，点击继续才会恢复处理。存在未结束任务时，关闭标签会先询问并等待清理；未确认的提交结果与临时文件警示会保留到用户明确处理。文件夹递归、断点续传与退出后的队列恢复仍在后续规划中。权限规则、测试状态及具体操作见 [SFTP 文件传输](Docs/M9/SFTP文件传输.md)。

### 使用本机终端与设置

关闭全部远程标签后，点击 **＋ → 打开本机终端**，即可使用当前用户的默认 Shell。初始目录为用户主目录，可以执行 `pwd`、`ls`、`top` 等本机命令；输入 `exit` 退出后可重新打开。

通过 **⋯ 更多操作 → 设置** 或 **⌘,** 打开设置：

- 选择字体、字号与终端配色主题。
- 滚屏历史默认 **10000 行**，可设置为 1000–100000 行。
- 连接期间的字体与字号调整在下一次连接 / 重新打开 Shell 时生效；配色和历史上限即时生效。

## 当前进度

当前已实现会话管理、SSH 连接、终端、多标签、左右并列 / 上下堆叠、本机 Shell、SFTP 目录浏览及普通文件传输。**文件夹递归传输、端口转发、跳板机、批量输入、快速命令、日志、Zmodem 和配置导入仍在后续规划中。**

M9.0 已完成系统 OpenSSH 无 PTY 管道与自有 SFTP v3 协议层验证，包含授权 Linux 虚拟机的密码和私钥登录。M9.1 在此基础上接入右侧目录面板，已通过模型、中英文界面、终端宿主保留与真实隔离 sshd 的目录浏览检查；本轮真实虚拟机的手工文件面板与密码 UI 验收仍待执行。详细结果分别见 [SFTP 底层验证](Docs/M9/SFTP技术验证.md) 和 [SFTP 目录浏览](Docs/M9/SFTP目录浏览.md)。

M9.2 的 Debug / Release 回归、传输引擎、本机文件系统、队列和真实隔离 sshd 的 1 MiB 文件往返、确认替换均已通过。中英文界面的字段、滚动和布局检查及截图目视检查通过；实际鼠标点击、本机文件选择器和个人服务器手工传输仍待验收。实际范围见 [SFTP 文件传输记录](Docs/M9/SFTP文件传输.md)。

中文与 emoji 的显示已有验证；完整真实中文输入法候选交互、实际睡眠唤醒、保存密码后的最终包重启登录、macOS 14 实机及正式分发签名 / 公证仍有人工待验项。详细边界见 [验收记录](Docs/M6/验收矩阵.md)。

## 开发与验证

```sh
sh Scripts/test.sh
```

在具有图形桌面的会话中运行原生界面检查：

```sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh
```

默认验证使用隔离的临时数据与合成连接，覆盖凭据隔离、真实本地 PTY、背压、生命周期、标签与分屏、资源打包和应用搬迁。真实服务器、性能及 Keychain 重启集成的专项入口见 [性能与交付记录](Docs/M6/性能与交付记录.md)。

M9.1 的模型检查加入默认回归；文件面板原生 UI 检查包含在上述 `DOCKSHELL_UI_SMOKE=1` 入口中。真实本地 sshd 集成还覆盖目录浏览模型。各入口的通过范围与人工待验项见 [SFTP 目录浏览](Docs/M9/SFTP目录浏览.md)。

M9.2 的引擎、本机文件和队列专项入口及最终结果见 [SFTP 文件传输](Docs/M9/SFTP文件传输.md)。验证只使用合成文件、临时目录与生成的测试密钥，个人敏感文件不作为传输夹具。

M9.0 的默认回归还包含离线系统 SSH 管道、SFTP 协议与启动策略检查。需要运行生成测试密钥、独立 agent 和回环 sshd 的真实 SFTP 集成时：

```sh
sh Scripts/test-sftp.sh
sh Scripts/test-sftp.sh release
```

它不会启用系统“远程登录”，也不会修改个人 authorized_keys、现有 agent 或正式凭据。授权远端测试另有显式入口，认证输入方式和已验范围见 [SFTP 技术验证](Docs/M9/SFTP技术验证.md)；默认回归不访问个人服务器。

### GitHub Actions

`CI` 在提交到 `main`、向 `main` 创建 PR 或手动运行时进行编译、默认验证和 arm64 DMG 打包。`Release` 工作流根据标签发布：`v0.1.1` 这类标准版本生成普通 Release 并设为 **Latest**；`v0.1.1-preview.1` 这类预览标签生成 **Pre-release**。两者都将 DMG、SHA-256 校验文件和清单直接附到 **Assets**。手动运行仍可创建草稿供维护者核对。操作步骤、版本规则和完整文件见 [GitHub Actions 构建与发布](Docs/GitHub-Actions.md)。

### 项目结构

```text
DockShellApp/             应用入口与依赖组装
Packages/DockShellKit/    业务、协议、基础设施与原生终端界面
Localization/            简体中文与英文 String Catalog
Packaging/               应用信息、图标与分发资源
Scripts/                 构建、运行、验证与打包脚本
Tools/                   资源编译、辅助程序、DMG 布局与验证工具
Docs/                    架构、开发与验收文档
M0/                      SSH 底层路线的独立技术验证
```

### 主要依赖

| 组件 | 版本 / 来源 |
|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 固定 **1.19.0**，通过 Swift Package Manager 集成 |
| OpenSSH | macOS 自带的系统工具，通过自有协议和 PTY 适配 |
| SQLite | macOS 系统库 |
| [ArgumentParser](https://github.com/apple/swift-argument-parser) | 上游解析依赖 **1.8.2**，不链接进应用 |

M0 中的 Citadel / libssh2 探针与正式应用依赖相互独立。随应用分发的第三方声明见 [ThirdPartyNotices](Packaging/ThirdPartyNotices.txt)。

## 更多文档

- [M9.2 SFTP 文件上传、下载与传输队列](Docs/M9/SFTP文件传输.md)
- [M9.1 SFTP 目录浏览与使用说明](Docs/M9/SFTP目录浏览.md)
- [M9.0 SFTP 技术验证与验收边界](Docs/M9/SFTP技术验证.md)
- [GitHub Actions 构建与发布](Docs/GitHub-Actions.md)
- [开发过程与版本调整记录](Docs/Development-History.md)
- [左右并列与上下堆叠工作区](Docs/M8/横排与竖排.md)
- [私钥、ssh-agent 与连接恢复](Docs/M5/私钥Agent与连接恢复.md)
- [分发、签名与公证准备](Docs/M6/分发准备.md)
- [不安装完整 Xcode 的构建方案](Docs/不安装Xcode的构建方案.md)
- [M0 技术验证与 SSH 路线对比](Docs/M0/SSH底层路线对比.md)
