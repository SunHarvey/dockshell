# M4：密码 SSH 与主机信任

> 本文保留 M4 历史实现与验收记录。当前功能、认证范围和心跳策略见 [M5 文档](../M5/私钥Agent与连接恢复.md)。

日期：2026-10-28。产品名为 DockShell；当前工程仍位于 `/Users/harvey/Documents/github-code/DeckShell`。本轮实现 M4，保留 M2 的会话、SQLite、Keychain 与 M3 的离线终端和设置。

## 已实现

- 使用系统 `/usr/bin/ssh` 建立单会话密码连接，打开真实交互 shell。
- 首次连接展示完整候选主机公钥的算法与 SHA-256 指纹，由用户明确批准。
- 应用独立的 `known_hosts` 保存完整主机公钥，再次连接严格匹配；密钥变化时拒绝继续。
- 在完成主机信任流程后读取会话引用的 Keychain 密码；没有已存密码时弹出临时密码输入框。
- 连接中、已连接、已断开、连接失败的可见状态，以及取消连接、主动断开、远端退出处理。
- 真实 PTY 输入输出、窗口行列数同步、UTF-8 中文与 emoji、全屏程序及大输出。
- 连接期间固定字体与字号；配色和滚屏历史上限仍可即时调整。
- 所有新增用户文案进入中英双语 String Catalog；当前为 155 个类型化键。

私钥、私钥口令与 ssh-agent 登录保留在 M5。当前会话编辑器允许保存这些配置，但连接入口会明确提示其所属阶段；协议适配器也会在扫描主机或读取凭据前拒绝不支持的认证方式。本轮没有实现多标签、分屏、SFTP、转发、跳板机、快速命令或终端日志。

## 运行与手工验证

先用 ⌘Q 退出旧进程，然后在当前工程中执行：

```sh
cd /Users/harvey/Documents/github-code/DeckShell
sh Scripts/run.sh zh-Hans
```

无需安装完整 Xcode 或登录 Apple Account。脚本使用当前 Command Line Tools、SPM 和系统框架，生成并打开 `Build/debug/DockShell.app`。应运行打包后的应用；直接 `swift run DockShell` 不负责组装资源和签名 helper。

1. 新建或选择一个密码认证会话，填写主机、端口与用户名。需要记住密码时，在会话编辑器中保存到 Keychain；不保存时，连接过程中输入的密码仅用于本次连接。
2. 点击“连接”。首次连接会显示主机算法和 SHA-256 指纹，应通过服务器管理界面等可信渠道核对后批准。取消后不保存该主机，也不会读取或请求密码。
3. 已有 Keychain 密码时直接取用；引用缺失或未保存密码时显示临时密码输入框。输入框提交或关闭后清空，不将临时密码补写到会话或 Keychain。
4. 连接成功后输入命令，调整窗口大小，检查底部行列数。可在服务器中运行 `stty size`、`vim -u NONE -n`、`top`、`seq 1 20000`，以及 `printf '中文🙂\n'`。这些验证不需要修改服务器配置。
5. 点击“断开连接”结束本次连接；远端执行 `exit` 也会自动更新状态。断开后可再次点击“连接”。此处是用户主动重新建链；心跳、网络黑洞和睡眠唤醒处理仍属于 M5。

主机公钥变化会显示明确错误，不自动接受新公钥，也不通过关闭严格校验继续连接。当前没有自动替换已信任主机密钥的入口。

## 分层与协议边界

```text
WorkspaceView / SSHSessionPane
    │ MainActor 状态与用户交互
    ▼
SSHSessionController ───── SSHInteraction protocol
    │                         ▲
    │ SSHTransport protocol   │ SSHConnectionPrompts
    ▼                         │
OpenSSHTransport ──────────────┘
    ├── SSHHostKeyScanner → OpenSSHHostKeyScanner → /usr/bin/ssh-keyscan
    ├── HostKeyTrustStore → OpenSSHHostKeyStore → 应用 known_hosts
    ├── CredentialStore → KeychainCredentialStore
    └── SSHConnection → OpenSSHConnection
            ├── OpenSSHCredentialBroker → 签名 helper + 本地 Unix socket
            └── SSHSessionChannel → PTYProcessChannel → 系统 /usr/bin/ssh
                    │ 原始字节，4 KiB pump
                    ▼
             TerminalSurface protocol → SwiftTerm AppKit 适配器
```

UI 不启动 SSH 进程，不拼接远端命令，不依赖具体 SSH 库。`SSHTransport`、`SSHConnection`、`SSHSessionChannel`、`SSHSessionOutcome`、`SSHInteraction`、`HostKeyTrustStore` 与 `SSHHostKeyScanner` 都是自有协议。未来 SFTP 和转发可增加独立通道，不能将二进制文件协议混入终端 PTY。

`SSHSessionController` 在终端视图挂载后才启动连接，使用真实行列数申请 PTY。连接、输入、输出和尺寸任务有独立生命周期；连接代次标识隔离旧任务的迟到结果，旧视图回调也会按来源身份过滤。关闭视图、取消确认或主动断开都会停止所属任务并回收连接。

Swift 负责 Actor、async/await、协议、状态和业务规则；自有小型 C 模块封装 PTY、`posix_spawn`、`poll`、进程回收和受限凭据 IPC。它是本项目源代码，通过 SPM 编译，不是新增第三方库。没有在 fork 后运行 Swift，也没有引入嵌套 DispatchQueue 回调。

## 主机信任与 known_hosts

`ssh-keyscan` 只发现候选公钥，扫描结果本身不构成信任。扫描不发送认证材料，stdout 限制为 64 KiB；工作线程执行子进程、读取、超时和回收，取消会终止并回收扫描进程。原始 banner 和 stderr 不进入日志或用户错误。

端点会规范化主机名、IPv6 和端口，拒绝选项前缀、空白、控制字符、通配符等输入。公钥会验证 SSH wire 字段、算法与长度，再计算 SHA-256 指纹。当前候选算法范围是 Ed25519、RSA 和标准 NIST ECDSA；不将证书、未知格式或损坏数据当成可批准的普通主机公钥。

信任顺序是：

1. 读取应用已存公钥，扫描候选公钥。
2. 首次主机要求用户批准完整候选公钥集合；拒绝或取消时不写入、不读取 Keychain、不请求密码。
3. 已知主机只采用扫描与已存公钥的交集；扫描新出现的其他公钥不会自动成为信任项。完全不匹配时终止。
4. 完成信任后，才读取已引用凭据或请求临时密码。
5. 真实 SSH 再进行一次握手，使用严格校验和本次允许的已信任算法。扫描和真实连接之间服务器或 DNS 改变，也必须通过这次严格公钥验证后才能认证。

存储路径由系统 Application Support API 解析，位于应用的 `DockShell/known_hosts`。它与用户的 `~/.ssh/known_hosts` 分离，内容为端点、算法和完整 Base64 公钥，不含密码。端口分别建档。

首次批准按完整字节序列写入私有临时文件，设为 0600，`fsync` 后原子重命名，再同步父目录；跨进程文件锁防止并发覆盖。已存在的不同公钥集合不能由 `approve` 覆盖。损坏、高版本、权限不安全或符号链接文件会明确报错并保留，不能静默重建或变成“首次信任”。新建应用目录为 0700；不会擅自修改已有父目录权限。

传给 SSH 的选项固定为 `UserKnownHostsFile=${DOCKSHELL_KNOWN_HOSTS}`，真实路径放在非敏感子进程环境变量中。OpenSSH 在配置分词后展开一次环境变量，避免路径中的空格、百分号、引号、反斜杠或 `${...}` 被重新解释。此路径处理已对系统 SSH 严格匹配做过实际验证。[OpenSSH 主机文件配置](https://man.openbsd.org/ssh_config#UserKnownHostsFile)

真实连接使用 `-F none`、`StrictHostKeyChecking=yes`、应用专属主机文件、`GlobalKnownHostsFile=/dev/null` 和 `UpdateHostKeys=no`；不导入用户或系统 SSH 配置，不启用 DNS 主机信任、代理、连接复用或转发。`EscapeChar=none` 关闭本地 SSH 转义命令。

本轮不隐式启用旧加密算法。RSA 公钥的存储格式名仍为 `ssh-rsa`，协商允许的签名为 `rsa-sha2-512` / `rsa-sha2-256`；不会因此启用 SHA-1 `ssh-rsa` 签名。没有追加 aes-cbc 或 `diffie-hellman-group14-sha1`。旧服务器兼容设置需后续独立设计和批准。[OpenSSH 旧算法说明](https://www.openssh.org/legacy.html)

## 密码、签名 helper 与认证就绪

密码只从自有 `CredentialStore` 或临时安全输入框进入内存。会话数据库和 known_hosts 都不保存密码。连接参数、子进程环境、临时文件和日志均不包含密码。

`OpenSSHCredentialBroker` 为每次连接创建独立的 0700 临时目录和 0600 Unix socket；目录内只有 socket，不写凭据文件。环境中仅放 socket 路径、随机 nonce、helper 路径和固定 askpass 配置。nonce 是关联标识，不是密码。

broker 只接受同时满足以下条件的请求：

- socket 对端 UID 与应用一致。
- 对端是本次 `posix_spawn` 返回的 SSH PID 的直接子进程。
- 父进程开始时间与绑定时一致，防止 PID 重用。
- 对端可执行文件路径与固定 helper 一致。
- 对端运行时代码满足启动前记录的 helper 签名 requirement。
- 请求的随机 nonce 与本次连接匹配。

密码最多发给一个合格请求；即使该请求中途断开，也不会重发。C 缓冲在交付、取消或结束时清除。Swift 输入和 `Data` 的生命周期同样只在本次连接内；不把这视为操作系统之外的绝对内存取证防护。

`SSH_ASKPASS_REQUIRE=force` 让系统 SSH 通过 helper 的私有 stdout 管道取得密码，不向终端流注入，也不靠识别 `password:` 等提示文本。认证约束为 password，禁用 publickey、agent、keyboard-interactive、hostbased 和 GSSAPI，且仅允许一次密码请求。[OpenSSH askpass 实现](https://github.com/apple-oss-distributions/OpenSSH/blob/main/openssh/readpass.c)

系统 askpass 的输入边界为 1–1023 个 UTF-8 字节，不能包含 CR、LF 或 NUL。应用和 helper 两端都检查，并显示明确错误，不截断后尝试认证。

收到终端输出、banner 或进程仍存在，都不代表登录成功。固定 `LocalCommand` 在 SSH 完成认证后执行签名 helper 的 `--ready` 模式，通过同一受限 IPC 通知 READY，控制器才进入“已连接”。这个命令只包含固定、正确引用的 helper 路径，不插入主机、用户名、远端输出或密码。helper 路径的 shell 引用与百分号转义经过系统 `ssh -G` 离线解析验证。[OpenSSH LocalCommand 配置](https://man.openbsd.org/ssh_config#LocalCommand)

SSH stderr 使用独立管道，最多保留 32 KiB 到内存，超出部分继续排空并丢弃，避免子进程堵塞。它仅用于固定模式的友好错误分类，不用于建立信任或判断认证成功，也不原样展示、记录或持久化。密码错误、拒绝连接、超时、网络不可达、主机变化和 helper 不可用均映射为 String Catalog 文案。

helper 随应用置于 `Contents/Helpers`，打包时先签名 helper，再签名应用。当前是本地 ad-hoc 签名，不需要账号；正式 Developer ID、公证和稳定分发签名属于后续交付。

## PTY、背压与窗口变化

生产 PTY 的初始 slave 保持正常 cooked 模式，并启用 `IUTF8`。系统 SSH 先把这些属性传给远端 PTY，再自行把本地终端切为 raw。不能在启动前直接 `cfmakeraw`：那会让远端继承错误的回显、规范输入和换行处理属性，导致普通输出排成阶梯、输入删除行为异常。二进制测试 fixture 会先检查生产默认值，再自行切换 raw。

helper 在新 session 内取得控制终端和前台进程组，再 `execve` 固定的 `/usr/bin/ssh`。没有 shell 拼接远端命令。窗口变化通过本地 PTY 的 `TIOCSWINSZ` 产生 SIGWINCH，再由 SSH 发送远端窗口变化请求。

```text
远端 shell ↔ SSH ↔ 内核 PTY
                    ↕ poll + wake pipe（专用 supervisor）
           输入环形缓冲 64 KiB / 输出环形缓冲 64 KiB
                    ↕ async read / ordered write
               PTYProcessChannel Actor
                    ↓ 每次最多 4 KiB
               TerminalIOPump Actor
                    ↓ 等待本块渲染完成再读下一块
               MainActor / TerminalSurface / SwiftTerm
```

接收缓冲满时停止读取 PTY，让背压传回 SSH；不会把读取事件转存成无界 `AsyncStream`。写入有序处理部分写入，缓冲满时挂起。输入控制器另有 1 MiB 上限，整次输入超限时明确拒绝，不部分发送。

输出等待注册在已有 supervisor 上，完成后恢复 Swift continuation；不会为每个 4 KiB 包创建线程。空闲 supervisor 阻塞在 `poll`，通过 wake pipe 响应输入、取消和关闭，没有终端周期轮询。进程等待等少数阻塞操作使用专用线程，网络和文件 IO 不在 MainActor 执行。

远端输入保持原始字节，不使用离线演示的 CR→CRLF 转换，也不在客户端重复回显。收到的终端字节按序送入解析器；滚屏历史仍按设置裁剪，默认 10000 行，不等同于永久日志。

## 字体与设置策略

**2026-10-30 更新：下述暂缓策略为 M4 历史决策。当前已获准接入模式保留补丁，字体与字号保存后即时应用，见 [终端设置即时生效](../终端设置即时生效.md)。**

用户已同意：在“连接中”和“已连接”期间固定本次字体与字号，新设置于下次连接生效；配色主题和历史上限即时生效。界面在有待应用字体变化时显示提示。

原因是原版 SwiftTerm 1.19.0 修改字体会 soft-reset 部分协议模式，可能影响运行中的 vim 等程序。控制器只冻结字体字段，不冻结主题和历史；没有通过 fork、补丁或上游私有 API 修改该行为。断开后再连接会使用最新字体设置。

## 自动检查

默认检查只使用临时数据、合成凭据和本地 PTY，不连接真实服务器，也不读取个人私钥或已有 Keychain 项：

```sh
sh Scripts/test.sh
```

具有桌面会话时，加入 SwiftUI/AppKit 终端检查：

```sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh
```

Release 对应命令：

```sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh release
```

真实 Keychain 检查只操作随机测试 service，并在结束时删除测试项：

```sh
DOCKSHELL_KEYCHAIN_TEST=1 sh Scripts/test.sh
```

| 检查 | 覆盖内容 |
|---|---|
| 字符校验 | 合法 ASCII / 中文 / emoji、非法控制字符与主机语法、IPv6 归一化、字体名和分组；覆盖优化构建下的等价行为 |
| M2/M3 回归 | 会话、凭据清理、SQLite、设置、离线通道、颜色、Unicode、IME 提交与生命周期 |
| M4 主机信任 | 端点/公钥验证、首次批准、完整公钥持久化、端口隔离、变化拒绝、损坏和未来格式保留、权限/锁/符号链接 |
| M4 凭据 | 合格签名 helper、错误 nonce/路径/父进程/替换签名拒绝、一次性密码、READY、绑定竞态、取消与清理、非法密码边界 |
| M4 PTY | cooked/IUTF8 默认属性、控制终端、SIGWINCH、4 MiB 逐字节二进制顺序、双向 IO、64 KiB 背压、32 KiB 独立诊断、取消、EOF 与回收 |
| M4 Transport | 信任先于凭据、拒绝/变化/取消时零密码访问、首次/重复连接、临时密码、不支持认证提前拒绝、严格参数、特殊 helper 路径的系统 `ssh -G` 解析、友好错误类型 |
| M4 Flow | 挂载后连接、原始 UTF-8 输入、4 KiB 渲染、尺寸更新、字体冻结及主题/历史即时应用、替换视图、迟到输出隔离、1 MiB 输入上限、提示取消和控制器释放 |
| 应用打包 | helper 与应用本地签名、资源和 helper 完整性、复制到工程外并隐藏原构建目录后再次运行检查 |

默认脚本不把测试虚拟机地址或密码写入工程。对真实服务器的测试单独在用户授权下执行。

## 本轮实测与验收边界

宿主为 macOS 27.0.1 / arm64，Apple Swift 6.4、SDK 27.0，系统 OpenSSH 10.3p1。最低部署目标仍为 macOS 14；这不是 macOS 14 实机运行结果。

Debug 与 Release 完整检查均已通过，包括 M2/M3 回归、M4 Validation / Flow / Transport、真实本地 PTY、SwiftUI/AppKit、签名与工程外搬迁。应用与嵌套 helper 的严格签名复查通过；Release 两个可执行文件的 Mach-O 最低版本均为 14.0。

对用户授权的私网 Linux 虚拟机，使用 `root` 会话进行了实际检查。测试会话关闭“记住密码”，通过应用临时密码框和正式 M4 broker 登录，没有将真实密码写入文件、日志或文档。公开记录省略该虚拟机的具体地址。

| 实际检查 | 结果与边界 |
|---|---|
| 主机扫描 | Ed25519 / RSA 指纹与事先独立核验值一致；扫描中取消可及时回收子进程 |
| 特殊 known_hosts 路径 | 含空格、百分号、引号、反斜杠和 `${literal}` 的临时路径，经系统 SSH 严格匹配成功；此项禁用认证 |
| 密码登录 | 应用首次确认、临时密码、真实交互 shell 成功；最终 Release 再次登录成功，重启后沿用已批准主机记录 |
| UTF-8 PTY 属性 | 最终 Release 的远端 `stty -a` 显示 `iutf8`、`opost`、`onlcr`、`icanon` 和 `echo` 已启用，换行正常 |
| 中文与 emoji | 中文/emoji 粘贴、`printf` 输出、vim 内存缓冲内容显示正确；未通过此项承诺全部输入法候选交互 |
| 窗口大小 | 界面从 101 × 32 调整到 286 × 73，远端 `stty size` 返回对应行列；列在前、行在后为应用显示顺序 |
| 全屏程序 | vim 缓冲显示正确；top 在窗口变化后的下一次重绘中按新尺寸布局 |
| 大输出 | `seq 1 20000` 到达末尾并返回 shell；尚不能据此替代网络背压长时压力测试 |
| 结束连接 | 主动断开和远端 `exit` 都能自动更新应用状态 |

本次 VM 使用临时密码，因此“真实 VM 密码来自 Keychain 的回读登录”仍待单独验收。M2 已通过随机 service 的真实 Keychain 增、读、删检查，但不能将它等同于这台 VM 上的完整保存、重启、取用登录链路。

仍待后续验收：macOS 14 实机；真实中文输入法连续组合、候选选择与定位；htop；网络黑洞、keepalive、睡眠唤醒后的手动重连；私钥格式与口令、ssh-agent；长时内存、网络大输出与空闲 CPU。M5 继续处理认证与连接恢复，M6 完成目标环境和性能矩阵。

## Release 字符校验修复

本轮完整 Domain 模块的 Swift 6.4 优化构建暴露了 `CharacterSet` 绑定方法引用的误判：同样的合法会话在 Debug 通过，Release 却可能报主机或名称无效。独立的 `-O` / whole-module 最小复现也观察到此差异。将五处绑定方法引用改为等价显式闭包后，合法与非法输入在两种构建中保持一致；未关闭优化、放宽输入规则或跳过原有断言。`M4ValidationVerification` 与全部 M2 回归覆盖该路径。该结论针对本机工具链的实测行为，未把它当成所有 Swift 版本的通用问题。

## 依赖与构建限制

| 依赖 | 固定版本 / 提交 | 地址或集成方式 |
|---|---|---|
| SwiftTerm | 1.19.0 / `464df5207fc2432e16c9a23abe538187196daf5f` | `https://github.com/migueldeicaza/SwiftTerm.git`，原版 SPM |
| ArgumentParser（上游解析依赖） | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | `https://github.com/apple/swift-argument-parser`，不链接进本应用 |
| OpenSSH | 跟随目标 macOS | 系统 `/usr/bin/ssh` 与 `/usr/bin/ssh-keyscan` |
| SQLite、Security、CryptoKit、POSIX | 跟随系统 SDK / macOS | 系统库和框架，无额外 SPM 第三方依赖 |

本轮没有新增第三方依赖、个人 fork 或第三方补丁；正式应用没有引入 Citadel、libssh2 或 Homebrew OpenSSL。SwiftTerm 原版许可仍随资源分发，SPM 解析版本仍由根 `Package.resolved` 锁定。

CLT 缺少 Metal 离线工具，公共构建脚本继续显式使用 `--build-system native`。此构建方式已弃用，将来可能移除；工具链升级必须重新验证。没有修改上游资源或 manifest，也不能据本次成功保证未来 CLT 版本无需调整。插件审计和资源查找细节见 [M3 文档](../M3/离线终端与设置.md)。

当前输出为宿主架构、本地临时签名的开发应用；Developer ID、公证、双架构发行与实际最低系统验收尚未交付。

## 完整文件索引

以下链接指向本次新增或调整的完整源文件。构建产物不属于源文件交付；依赖版本未改变。

| 范围 | 完整文件 |
|---|---|
| SPM 工程与 helper 产品 | [根 Package.swift](../../Package.swift)、[分层包 Package.swift](../../Packages/DockShellKit/Package.swift) |
| 主机信任值类型与协议 | [HostTrust.swift](../../Packages/DockShellKit/Sources/DockShellDomain/HostTrust.swift) |
| 认证交互、错误与完成状态协议 | [SSHInteraction.swift](../../Packages/DockShellKit/Sources/DockShellDomain/SSHInteraction.swift) |
| 主机扫描 | [OpenSSHHostKeyScanner.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHHostKeyScanner.swift) |
| 主机存储 | [OpenSSHHostKeyStore.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHHostKeyStore.swift) |
| SSH 适配器、参数和错误分类 | [OpenSSHTransport.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHTransport.swift) |
| 凭据桥接 Actor | [OpenSSHCredentialBroker.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHCredentialBroker.swift) |
| PTY 通道 Actor | [PTYProcessChannel.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/PTYProcessChannel.swift) |
| 系统存储路径 | [AppPaths.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/AppPaths.swift) |
| 自有 C 接口 | [CDockShellPTY.h](../../Packages/DockShellKit/Sources/CDockShellPTY/include/CDockShellPTY.h)、[DockShellCredentialBroker.h](../../Packages/DockShellKit/Sources/CDockShellPTY/include/DockShellCredentialBroker.h) |
| 自有 C PTY 与凭据实现 | [pty_runtime.c](../../Packages/DockShellKit/Sources/CDockShellPTY/pty_runtime.c)、[credential_broker.c](../../Packages/DockShellKit/Sources/CDockShellPTY/credential_broker.c) |
| 固定启动 / askpass / READY helper | [Tools/SSHHelper/main.c](../../Tools/SSHHelper/main.c) |
| SSH 终端控制器 | [SSHSessionController.swift](../../Packages/DockShellKit/Sources/DockShellTerminalUI/SSHSessionController.swift) |
| 通用终端控制边界和桥接 | [TerminalSurface.swift](../../Packages/DockShellKit/Sources/DockShellTerminalUI/TerminalSurface.swift)、[TerminalViewBridge.swift](../../Packages/DockShellKit/Sources/DockShellTerminalUI/TerminalViewBridge.swift) |
| 离线终端对公共边界的适配 | [OfflineTerminalController.swift](../../Packages/DockShellKit/Sources/DockShellTerminalUI/OfflineTerminalController.swift) |
| SSH 页面、信任和临时密码界面 | [SSHSessionPane.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/SSHSessionPane.swift) |
| 提示框与取消生命周期 | [SSHConnectionPrompts.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/SSHConnectionPrompts.swift) |
| 会话连接入口与窗口清理 | [WorkspaceView.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift) |
| 双语错误与界面文案 | [Localization.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/Localization.swift)、[Localizable.xcstrings](../../Localization/Localizable.xcstrings) |
| App 依赖组装与异步启动 | [AppContainer.swift](../../DockShellApp/AppContainer.swift)、[DockShellApp.swift](../../DockShellApp/DockShellApp.swift) |
| helper 打包与本地签名 | [Scripts/package-app.sh](../../Scripts/package-app.sh) |
| 验证入口 | [Tools/Verification/Verification.swift](../../Tools/Verification/Verification.swift) |
| 字符校验优化回归 | [M4ValidationVerification.swift](../../Tools/Verification/M4ValidationVerification.swift) |
| 会话、字体和分组校验等价改写 | [SessionEditing.swift](../../Packages/DockShellKit/Sources/DockShellDomain/SessionEditing.swift)、[TerminalSettings.swift](../../Packages/DockShellKit/Sources/DockShellDomain/TerminalSettings.swift)、[WorkspaceService.swift](../../Packages/DockShellKit/Sources/DockShellApplication/WorkspaceService.swift) |
| 主机信任检查 | [M4HostTrustVerification.swift](../../Tools/Verification/M4HostTrustVerification.swift) |
| 凭据 IPC 检查 | [M4CredentialVerification.swift](../../Tools/Verification/M4CredentialVerification.swift) |
| 真实 PTY 检查 | [M4PTYVerification.swift](../../Tools/Verification/M4PTYVerification.swift) |
| Transport 策略检查 | [M4TransportVerification.swift](../../Tools/Verification/M4TransportVerification.swift) |
| SSH 控制器完整链路检查 | [M4FlowVerification.swift](../../Tools/Verification/M4FlowVerification.swift) |
| M3 历史记录补充 | [M3 离线终端与设置](../M3/离线终端与设置.md) |
| 项目状态与本轮交付记录 | [README.md](../../README.md)、[DockShell-开发方案.md](../../DockShell-开发方案.md)、[本文件](密码SSH与主机信任.md) |

沿用而未更换的会话仓库、Keychain、设置、IO pump 和 SwiftTerm 独立诊断实现，可继续通过 [M2 完整索引](../M2/会话与凭据管理.md) 与 [M3 完整索引](../M3/离线终端与设置.md) 查阅。
