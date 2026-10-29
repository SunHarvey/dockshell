# DockShell 开发方案

- 整理日期：2026-10-18
- 方案状态：2026-10-28 已推进 M5 私钥、agent 与连接恢复；SSH 采用系统 OpenSSH，持久化采用系统 SQLite
- 产品名称：DockShell
- 统一目标根目录：`/Users/harvey/Documents/github-code/DockShell`
- 当前开发目录：`/Users/harvey/Documents/github-code/DeckShell`；按本轮要求直接在当前目录开发，未自动重命名
- 2026-10-19 环境约束：用户完全不登录 Apple ID / Apple Account；需要浏览器或第三方安装器账号认证的下载方式均不符合要求

本文记录项目目录结构、模块职责、里程碑、依赖基线和待确认事项。所列文件为规划，随里程碑逐步添加；依赖能力检查不等同于已通过编译或实际服务器验收。

## 1. 总体方案

当前采用 **根 SwiftPM 应用包 + 本地 SPM 分层包 + 自有 CLT 构建脚本**。不安装完整 Xcode，不登录 Apple Account，通过独立编译模块限制依赖方向。原 `.xcodeproj` 目录图保留为早期规划参考；当前实际目录和完整文件见 [M1 工程基座](Docs/M1/工程基座.md)。

详细门槛与历史实测见 [CLT 构建方案](Docs/不安装Xcode的构建方案.md)。2026-10-27 用户已批准改用系统 SQLite，解除原 SwiftData 宏插件对后续持久化的阻碍。M3 已通过显式 native 构建接入原版 SwiftTerm；native 构建的弃用风险仍保留。M4 已接入系统 OpenSSH 密码认证与主机信任，并按用户确认的策略将真实连接期间的字体变化延后到下次连接，见 [M4 文档](Docs/M4/密码SSH与主机信任.md)。未修改第三方库。

遵循以下技术约束：

- 应用自身代码使用 Swift 6、async/await 和 Actor。
- 最低系统版本为 macOS 14。
- UI 以 SwiftUI 为主，终端等复杂交互通过 AppKit 与 `NSViewRepresentable` 桥接。
- 终端模拟使用 SwiftTerm；用户已依据 M0 选择系统 OpenSSH，协议层通过自定义 protocol 隔离进程与协议细节。第二阶段 SFTP 的结构化适配单独设计。
- 系统 SQLite 保存会话配置（2026-10-27 已批准替代 SwiftData），Keychain 保存密码和私钥口令。
- 第三方依赖通过 Swift Package Manager 管理。
- 分发目标为 Developer ID 签名和公证，存储路径通过系统 API 获取。
- 用户可见字符串使用 String Catalog，支持简体中文和英文。
- 采用 MVVM 和清晰分层，由应用入口完成依赖注入。
- 界面、配色和代码独立设计，不复用商业软件的图标、界面素材或代码。

### 需提前处理的兼容性风险

**Citadel 0.12.1 的公开交互 PTY 接口标注为 macOS 15+，且没有现成的 ssh-agent 认证入口。**因此，不能直接承诺原版依赖满足全部要求；兼容性验证移至新增的 M0。

M0 仅编写无 UI 的最小验证代码，并对比三条路线。不预先选择依赖策略；未经用户明确批准，不 fork，也不向第三方源码打补丁。Citadel 的最小补丁只分析所需范围与维护代价。

来源：

- [Citadel 0.12.1 PTY 源码](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/TTY/Client/TTY.swift)
- [Citadel 0.12.1 认证源码](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/SSHAuthenticationMethod.swift)

## 2. 项目目录结构

统一使用 `DockShell` 作为产品和类型命名；当前目录暂保留 `DeckShell`。以下是早期完整 Xcode 方案的目标目录参考，不代表当前已生成这些文件。当前纯 CLT 工程结构以 [M1 文档](Docs/M1/工程基座.md) 为准，持久化实现已改选 SQLite。

```text
/Users/harvey/Documents/github-code/DockShell/
├── M0/
│   ├── README.md                          # 验证方法、证据等级与运行边界
│   ├── Citadel/                           # 原版 Citadel 最小命令行探针
│   ├── LibSSH2/                           # C 库与 Swift 6 互操作探针
│   └── SystemSSH/                         # 系统 ssh 与 PTY 探针
├── DockShell.xcodeproj
├── DockShellApp/
│   ├── DockShellApp.swift
│   ├── AppContainer.swift                 # 依赖组装入口
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Localizable.xcstrings
│       └── Info.plist
├── Packages/
│   └── DockShellKit/
│       ├── Package.swift
│       ├── Sources/
│       │   ├── DockShellDomain/
│       │   │   ├── Models/
│       │   │   │   ├── SessionProfile.swift
│       │   │   │   ├── SessionGroup.swift
│       │   │   │   ├── AuthenticationMethod.swift
│       │   │   │   ├── ConnectionState.swift
│       │   │   │   └── TerminalSize.swift
│       │   │   ├── Ports/
│       │   │   │   ├── SSHTransport.swift
│       │   │   │   ├── SSHSessionChannel.swift
│       │   │   │   ├── SessionRepository.swift
│       │   │   │   ├── CredentialStore.swift
│       │   │   │   ├── HostKeyStore.swift
│       │   │   │   ├── SSHAgentClient.swift
│       │   │   │   └── SettingsRepository.swift
│       │   │   └── Errors/
│       │   │       └── DockShellError.swift
│       │   ├── DockShellApplication/
│       │   │   ├── Sessions/SessionService.swift
│       │   │   ├── Connections/ConnectionCoordinator.swift
│       │   │   ├── Connections/HostKeyVerificationService.swift
│       │   │   ├── Terminal/TerminalIOPump.swift
│       │   │   └── Settings/SettingsService.swift
│       │   ├── DockShellInfrastructure/
│       │   │   ├── Persistence/
│       │   │   │   ├── SessionRecord.swift
│       │   │   │   ├── SessionGroupRecord.swift
│       │   │   │   └── SwiftDataSessionRepository.swift
│       │   │   ├── Security/
│       │   │   │   ├── KeychainCredentialStore.swift
│       │   │   │   └── KnownHostsFileStore.swift
│       │   │   ├── SSH/
│       │   │   │   ├── BackendSSHTransport.swift    # 名称随 M0 路线决定
│       │   │   │   ├── BackendSessionChannel.swift
│       │   │   │   └── SSHAgentSocketClient.swift
│       │   │   ├── Settings/UserDefaultsSettingsRepository.swift
│       │   │   └── Storage/AppPaths.swift
│       │   ├── DockShellTerminalUI/
│       │   │   ├── TerminalSurface.swift
│       │   │   ├── SwiftTermTerminalView.swift
│       │   │   └── TerminalViewRepresentable.swift
│       │   └── DockShellFeatures/
│       │       ├── Workspace/
│       │       ├── Sessions/
│       │       ├── Connections/
│       │       ├── Settings/
│       │       └── Resources/Localizable.xcstrings
│       └── Tests/
│           ├── DomainTests/
│           ├── ApplicationTests/
│           ├── InfrastructureTests/
│           └── TerminalIntegrationTests/
├── DockShellUITests/
├── Release/
│   └── ExportOptions.plist
└── Docs/
    ├── 开发环境与目录调整.md
    ├── 不安装Xcode的构建方案.md
    ├── M0/
    │   ├── SSH底层路线对比.md
    │   ├── Citadel.md
    │   ├── LibSSH2.md
    │   └── SystemSSH.md
    ├── Architecture.md
    ├── CompatibilityMatrix.md
    └── Verification.md
```

## 3. 核心模块与职责

核心模块通过 SPM target 隔离。

| 模块 | 职责与边界 |
|---|---|
| `DockShellDomain` | 定义会话、认证配置、连接状态、终端尺寸、错误和协议。使用可跨并发边界传递的值类型，不依赖 SQLite、具体 SSH 后端或 SwiftTerm。 |
| `DockShellApplication` | 实现会话管理、连接流程、主机验证、凭据协调和终端数据流。仅依赖领域模型与协议。 |
| `DockShellInfrastructure` | 实现系统 OpenSSH、SQLite、Keychain、known_hosts 和设置存储适配器；agent 交互委托给系统 OpenSSH。C 指针和进程细节限制在这里。 |
| `DockShellTerminalUI` | 封装 SwiftTerm 的 AppKit 视图，处理终端显示、文本输入、鼠标和尺寸事件，通过 `NSViewRepresentable` 接入 SwiftUI。 |
| `DockShellFeatures` | SwiftUI 页面及 `@MainActor` ViewModel。负责展示和用户操作，不处理 SSH 库对象或数据库对象。 |
| `DockShellApp` | 创建具体实现并注入协议依赖，管理应用及窗口生命周期。 |

依赖方向：

```text
DockShellFeatures ────────→ DockShellApplication ──→ DockShellDomain
       │
       └─────────────────→ DockShellTerminalUI ───→ DockShellDomain

DockShellInfrastructure ──────────────────────────→ DockShellDomain

DockShellApp：组装上述模块，通过协议注入具体实现
```

### 关键类型

| 类型 | 职责 |
|---|---|
| `SSHTransport` | 建立、关闭 SSH 连接，发布连接事件，创建会话通道。 |
| `SSHSessionChannel` | 请求 PTY、启动 shell、收发原始字节、更新窗口尺寸、报告通道结束。与连接本身分离，为未来多通道留出空间。 |
| `ConnectionCoordinator` actor | 管理连接状态机、取消、断线、手动重连和资源释放；防止旧连接事件影响重连后的连接。 |
| `TerminalIOPump` | 按序传输终端字节，实施有界缓冲与背压，协调输入和输出。 |
| `SessionRepository` | 管理会话和分组；SQLite 连接与持久化记录不直接传入 UI。 |
| `CredentialStore` | 管理密码和私钥口令，业务层使用凭据引用访问。 |
| `HostKeyStore` | 持久化已信任主机的公钥、算法和匹配信息。 |
| `HostKeyVerificationService` | 比较已保存主机公钥，协调首次信任确认与密钥变化处理。 |
| `SSHAgentClient` | 抽象本机 agent 的身份枚举和签名交互；底层接入方式须由 M0 验证，系统 OpenSSH 路线可将 agent 交互委托给子进程。 |
| `TerminalSurface` | 定义终端呈现边界，使业务层不依赖 SwiftTerm。 |
| `SettingsRepository` | 保存字体、字号、主题和滚屏历史上限等非敏感设置；滚屏默认 10000 行，可在设置中调整。 |

### 第二阶段的扩展边界

通过“连接—通道—终端视图”分离，为后续多标签、分屏和多个会话保留空间。

`SFTPClient`、端口转发和工作区布局的边界记录在架构文档中，进入第二阶段时再落实具体协议与实现。第二阶段范围包括：

- 多标签、分屏、SFTP 文件面板。
- 本地、远程和动态端口转发，以及跳板机。
- 批量发送输入、快速命令、日志记录。
- rz/sz（Zmodem）。
- 导入 `~/.ssh/config` 与 Xshell `.xsh` 文件。

## 4. 并发、终端与安全约定

### 4.1 数据流与背压

- 网络输出始终保留原始字节，避免分块转换字符串破坏跨块 UTF-8。
- 使用按字节计量的有界缓冲，并将消费速度反馈至底层读取。
- 不能依靠丢弃数据或无限队列满足高吞吐要求。
- 仅在业务层增加有限队列不足以证明上游缓冲有界；必须验证网络通道到终端消费者的完整链路。

用户已确认“不丢数据”定义为：**收到的终端字节全部按序处理，滚屏历史采用有限上限。**默认上限为 **10000 行**，可在设置中调整。永久保留全部输出属于第二阶段日志功能。

### 4.2 界面响应与并发隔离

- AppKit 与 ViewModel 位于 `MainActor`。
- 终端按时间预算分批更新，避免每个网络包触发 SwiftUI 刷新。
- 网络、私钥读取、Keychain 和文件操作在主线程之外执行。
- Actor 用于状态隔离；具体 IO 适配器仍需保证执行位置和取消语义正确。
- 空闲时不运行持续刷新循环。
- 连接任务统一管理取消和清理，避免重连后保留旧任务、通道和事件监听。

### 4.3 输入、显示与窗口尺寸

- 沿用 SwiftTerm 的 AppKit 文本输入机制，保留 IME 组合文本过程。
- 不通过自行拦截全部键盘事件替代系统文本输入机制。
- 验证 256 色、TrueColor、鼠标、中文、emoji、组合字符及字体回退。
- 尺寸变化发送 SSH `window-change` 请求，由远端更新 PTY 并触发相应的 `SIGWINCH` 行为。
- 中文输入法和全屏程序必须通过真实交互验收。

参考：[Citadel 尺寸更新实现](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/TTY/Client/TTY.swift)。

### 4.4 凭据与主机身份

- SQLite 只保存认证方式、凭据标识和私钥文件引用。
- 密码与私钥口令进入 Keychain。
- 错误和诊断中不得包含认证材料。
- 首次主机指纹确认在发送认证材料之前完成。
- 保存完整主机公钥及算法，SHA-256 指纹用于展示。
- 已知主机密钥变化时阻止连接，明确提示原因。
- known_hosts 使用应用自有文件，串行、原子写入。

### 4.5 存储、本地化与错误

- 通过系统目录 API 定位应用存储目录，避免写死用户路径。
- 界面、菜单、验证消息及错误提示统一使用 String Catalog，包含简体中文与英文。
- 协议层返回结构化错误，由展示层转换为本地化说明。
- 断线检测结合通道结束、网络错误及超时机制；网络不可达不能被静默处理。
- keepalive 需要验证对“TCP 未关闭但远端已无响应”的断线检测，不能只判断本机网络路径。
- macOS 睡眠时保留已连接会话，唤醒后由协议心跳检测断线并提供手动重连；不自动重新认证。正在建立的认证过程在睡眠时取消。
- 私钥兼容矩阵分别列出 OpenSSH、老式 PEM、PuTTY `.ppk`，再区分密钥类型及加密参数；不支持时给出明确的本地化提示。
- 关键类型和协议提供文档注释，复杂并发、缓冲及安全逻辑补充必要注释。

## 5. 界面方向

建议采用原生侧栏、单终端工作区和紧凑连接状态区；会话编辑使用独立表单。

三套原创主题暂定为：

1. 石墨。
2. 深海。
3. 纸白。

具体配色在 M3 审阅。

## 6. 里程碑拆分

按顺序推进，每次只实现一个里程碑。完成后提供可运行工程、涉及的完整文件和验证步骤。

| 里程碑 | 交付内容 | 独立运行与验收方式 |
|---|---|---|
| **M0：技术验证** | 已提供三路线离线探针与报告；真实服务器和 macOS 14 验收仍待执行。 | 用户已选择系统 OpenSSH；历史推荐与证据保留，不 fork、不打补丁。 |
| **M1：工程基座（已交付）** | 创建原生应用、分层 target、Swift 6 模式、双语资源、原创主窗口，以及 CLT 打包脚本。 | 应用可启动；系统 SQLite 可通过 SPM 链接、系统 SSH 可用；部署目标为 macOS 14。SwiftTerm 正式接入留在 M3。 |
| **M2：会话与凭据管理（已交付）** | 新建、编辑、删除、分组、搜索；系统 SQLite 持久化和 schema 迁移；Keychain 密码及口令读写。 | 重启后会话仍在；数据库不包含密码或口令；验证凭据更新和删除失败时的处理。 |
| **M3：离线终端与设置（已交付）** | SwiftTerm 桥接、测试字节源、键盘与鼠标、IME、字体字号、三套原创主题；滚屏默认 10000 行并可调整。 | 无服务器也能运行；验证 256 色、TrueColor、中文、emoji、跨块 UTF-8、输入法、窗口缩放及滚屏上限设置。 |
| **M4：密码 SSH 与主机信任（已交付）** | 密码认证、交互 shell、首次指纹确认、known_hosts、连接状态和主动断开。 | 登录 Linux；验证接受、取消、再次连接及主机密钥不匹配流程；拒绝信任时不继续认证。 |
| **M5：私钥、agent 与连接恢复（已交付）** | 已确认格式的私钥及口令认证、本机 ssh-agent 认证、keepalive 心跳断线检测、超时和手动重连。 | 分别用密码、私钥和 agent 登录；测试错误口令、agent 不可用、黑洞网络、睡眠唤醒后的手动重连、反复重连后的资源释放，以及不支持的私钥格式提示。 |
| **M6：MVP 验收与分发准备（本机交付，目标环境待验）** | 全屏程序、中文及高吞吐验证，真实 Keychain 新进程验收、持久化路径防护、内存和空闲 CPU 测量；Apple Silicon 本地预览及签名、公证准备。 | 运行 vim、top、htop 并连续缩放；大输出校验字节完整性及内存稳定性；重启后从 Keychain 取凭据。实际公证需要用户的开发者签名环境。 |
| **M7：多标签（已交付本机预览）** | 原生 AppKit 标签栏、同一窗口的多个独立 SSH 终端、每标签认证 / 状态 / 重连、后台持续接收及独立关闭。 | 同一保存会话双开；切换不重连、不重建视图；输入与信任确认隔离；后台输出及协议回复正确；关闭一项不影响其他项，全部关闭后释放资源。 |
| **M8：横排 / 竖排与标签排序** | 一个连接对应一个原有标签，全部终端可横排 1×N 或竖排 N×1；编号位于最左侧、名称居中、标签支持拖动重排；移除底部两栏，将高度交给终端。 | 三连接严格三列或三行；重排与模式切换不增加连接或重挂终端；编号从 1 连续更新、面板按同序重排；PTY、输入、认证及 DSR 隔离。 |

用户于 2026-10-27 选择系统 OpenSSH，并批准将持久化改为系统 SQLite。2026-10-28 已完成 M6、M7 和 M8 多个本机预览；用户最新明确要求分屏可选横排或竖排，任意已打开数量均严格排成一行或一列，不新增标签或连接。build 7 按此语义替换自动网格。2026-10-29 的 build 8 按新确认加入标签左侧编号、居中名称、拖动排序及底栏移除；最新状态见[标签排序与终端空间说明](Docs/M8/标签排序与终端空间.md)，旧 build 实测保留为历史记录。没有 macOS 14 验收环境及 Developer ID 证书，M6 的相应待验项继续保留。若以后需要补丁、fork 或额外依赖，仍先列明具体变更和维护代价供用户批准；不得提前实施。

### M0 必须覆盖的评估维度

1. macOS 14 可用性与 Swift 6 并发封装。
2. 密码、私钥及本机 ssh-agent 认证。
3. PTY、交互 shell 及窗口尺寸变化。
4. 端到端背压、有界内存和原始字节完整性。
5. 旧算法兼容：aes-cbc、`diffie-hellman-group14-sha1`、`ssh-rsa`，区分 RSA 密钥与 RSA/SHA-1 签名。
6. 第二阶段 SFTP、本地/远程/动态端口转发、跳板机支撑度。
7. 维护风险、密码学依赖、个人 fork 依赖和官网分发成本。
8. keepalive、睡眠唤醒及连接恢复所需机制。
9. OpenSSH、老式 PEM 和 PuTTY `.ppk` 的支持与拒绝提示。

Citadel 路线分析 macOS 14 PTY、agent 和背压需要的最小补丁方案，但只提供设计，不创建 fork、不修改第三方源码。libssh2 路线说明 SPM C 模块集成与最终静态库/XCFramework 分发的区别。系统 OpenSSH 路线说明 PTY 子进程、结构化主机验证和 Keychain 凭据交付的边界。

## 7. 第三方依赖基线

M0 候选依赖与正式应用分开管理。正式 SSH 后端已选择系统 OpenSSH；M1 无第三方网络包，使用系统 SQLite 的 SPM C 模块。M3 已接入原版 SwiftTerm 1.19.0，实际依赖锁定于根 Package.resolved。以下表格保留候选评估基线。

| 库 | 建议版本 | SPM 地址 |
|---|---|---|
| SwiftTerm | **1.19.0** | `https://github.com/migueldeicaza/SwiftTerm.git` |
| Citadel | **0.12.1，仅 M0 候选验证** | `https://github.com/orlandos-nl/Citadel.git` |
| libssh2 | **1.11.1，仅 M0 候选验证** | `https://github.com/libssh2/libssh2.git`；通过自有 SPM C 模块集成，无官方原生 Swift Package 产品 |
| 系统 OpenSSH | **以目标 macOS 自带版本为准** | 系统 `/usr/bin/ssh`，无需 SPM 网络包 |

### 7.1 SwiftTerm

SwiftTerm 1.19.0 已接入 M3 并通过本机颜色、Unicode、组合输入契约、鼠标和释放检查。本机真实中文输入法已有组合与提交实测；最终预览包复查见 M6 验收矩阵。macOS 14 仍保留实机验收，不由本机部署标记替代。

其包采用 Swift 5 语言模式，因此应用自身的 Swift 6 并发检查不能等同于依赖已经通过同样检查。

来源：

- [SwiftTerm 1.19.0 发布记录](https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.19.0)
- [SwiftTerm 1.19.0 包配置](https://github.com/migueldeicaza/SwiftTerm/blob/v1.19.0/Package.swift)

### 7.2 Citadel

Citadel 0.12.1 实际依赖 `Wellz26/swift-nio-ssh`，版本范围为 `0.3.4..<0.4.0`，SPM 地址为 `https://github.com/Wellz26/swift-nio-ssh.git`。

它的 PTY 平台限制、外部签名接入和上游输出缓冲都需要验证，不能仅靠外层增加 Actor 解决。

M0 需要核实：

1. macOS 14 上交互 PTY 的可用实现路径。
2. 应用 Swift 6 严格并发模式下的适配边界。
3. ssh-agent 的异步签名接入方式。
4. 网络读取到终端消费之间的端到端背压。
5. 主机指纹确认等待时间与握手超时的协调。
6. 实际支持的私钥类型、文件格式、加密算法和参数范围。

M0 实际使用的验证依赖记录于对应路线报告。用户已选择系统 OpenSSH，因此 Citadel 与其传递依赖均不进入正式应用。M1 无网络包，不引入未批准的额外业务依赖。

来源：

- [Citadel 0.12.1 发布记录](https://github.com/orlandos-nl/Citadel/releases/tag/0.12.1)
- [Citadel 0.12.1 包配置](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Package.swift)
- [Citadel 0.12.1 TTY 数据流](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/TTY/Client/TTY.swift)
- [Citadel 0.12.1 认证入口](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/SSHAuthenticationMethod.swift)
- [NIOSSH 0.3.4 自定义签名接口](https://github.com/Wellz26/swift-nio-ssh/blob/0.3.4/Sources/NIOSSH/Keys%20And%20Signatures/CustomKeys.swift)
- [Citadel 0.12.1 主机验证及握手逻辑](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/ClientSession.swift)
- [Citadel 0.12.1 OpenSSH 私钥解析](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/OpenSSHKey.swift)

## 8. 用户已确认的决策与待定事项

### 8.1 整体方案

整体架构已认可。M0 离线验证和报告已提供；2026-10-27 用户要求在当前目录开始开发，并确认系统 OpenSSH 与系统 SQLite。M1 至 M6 已提供本机可运行交付，M6 仍保留目标环境待验项。用户于 2026-10-28 明确选择 M7 多标签并已获得本机预览，随后批准本轮 M8 基础分屏，只推进本里程碑。macOS 14 实机、实际睡眠及正式 Developer ID / 公证仍需对应环境。

### 8.2 依赖策略

用户已选择系统 OpenSSH，不引入 Citadel / libssh2 作为正式应用依赖。SQLite 使用 SDK 与系统库，无第三方 wrapper。**未经用户批准，不得 fork、打补丁或添加额外依赖。**

### 8.3 私钥管理

用户已选择 **A：引用用户选择的私钥文件，口令存 Keychain**。便于复用现有密钥；文件移动后需要重新选择。

### 8.4 MVP 范围细化

以下范围已全部确认：

- 分组先支持单层结构。
- ssh-agent 范围为本机 OpenSSH 兼容 agent。
- 私钥优先验证 OpenSSH Ed25519/RSA，具体格式支持以兼容矩阵为准。
- 收到的终端字节全部按序处理，滚屏历史默认 10000 行，可在设置中调整。

## 9. 开发环境现状

2026-10-27：继续使用现有 CLT，正式工程采用 SwiftPM + 自有打包脚本，不创建 `.xcodeproj`；SwiftData 已经用户批准替换为系统 SQLite。下段保留初次环境调查背景，其中账号下载不符合当前免 Apple Account 约束，不作为安装建议。

2026-10-18 检查时，开发环境指向 Command Line Tools，尚未安装完整 Xcode。本机为 macOS 27.0.1，现有 CLT 提供 Apple Swift 6.4 和 macOS 27 SDK，可以开展无 UI 的 M0 命令行验证。

Swift 6 语言能力的基础下限为 Xcode 16，但本轮 Citadel 解析依赖图包含 tools 6.4 的 swift-collections 1.7.3，实际需 Swift 6.4 工具链，不承诺当前图在 Xcode 16 下可用。已有 CLT 6.4 足以复现当前 M0 SSH 探针。若采用原 `.xcodeproj` 方案，完整 Xcode 可通过官网下载 `.xip` 安装，不需要登录 App Store；若用户本机不安装，需按 [CLT 构建方案](Docs/不安装Xcode的构建方案.md) 先明确完整应用的构建环境和 SwiftData 门槛。应用部署目标仍是 macOS 14。安装、验证和目录重命名命令见 [开发环境与目录调整](Docs/开发环境与目录调整.md)。

M0 报告见 [SSH 底层路线对比与推荐](Docs/M0/SSH底层路线对比.md)，完整验证代码入口见 [M0 README](M0/README.md)。历史推荐不等同于正式选型；当前以用户于 2026-10-27 明确选择的系统 OpenSSH 为准。

## 10. 迭代与交付约定

1. 先确认方案，再开始代码实现。
2. 每次只推进一个里程碑，保证该阶段可独立编译、运行。
3. 每次提供涉及的完整文件及路径，不使用省略代码的表达。
4. 列明第三方库名称、版本及 SPM 地址；未经核实的 API 明确标注。
5. 存在需求歧义或影响范围的多方案选择时，先说明取舍并确认。
6. 不引入未批准的额外依赖或功能。
7. 每个里程碑完成后说明实际验证结果、验证方式和剩余限制。

本轮推进 **M8：标签编号、拖动排序与终端空间调整**，保留横排 / 竖排规则，重排后按当前顺序连续编号，不新增连接。实际文件、使用方式和验证入口见 [README](README.md) 和 [标签排序与终端空间说明](Docs/M8/标签排序与终端空间.md)，方向规则见 [横排与竖排说明](Docs/M8/横排与竖排.md)；早期记录见 [自动网格](Docs/M8/自动网格.md) 与 [基础分屏历史说明](Docs/M8/基础分屏.md)，M7 历史交付见 [多标签说明](Docs/M7/多标签开发方案.md)；M6 原有结果与待验项见 [验收矩阵](Docs/M6/验收矩阵.md)、[性能与交付记录](Docs/M6/性能与交付记录.md) 和 [分发准备](Docs/M6/分发准备.md)。M5 已确认的策略继续适用：睡眠时保留已连接会话，唤醒后由协议心跳检测断线，并提供手动重连；不自动重新认证。
