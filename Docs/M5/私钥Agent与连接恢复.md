# M5：私钥、ssh-agent 与连接恢复

日期：2026-10-28。产品名为 DockShell；当前工程仍位于 `/Users/harvey/Documents/github-code/DeckShell`。本轮在 M4 的真实密码终端上继续实现 M5，不增加第二阶段的多标签、SFTP、转发或跳板机功能。

## 本轮行为

- 支持用户所选外部私钥文件，区分无口令和需要口令的容器。
- 私钥口令来自会话引用的 Keychain，或者本次连接的临时安全输入框。
- 支持现有本机 OpenSSH 兼容 ssh-agent；不自动添加密钥、不转发 agent。
- 系统 SSH 显式启用 15 秒协议心跳和 3 次无响应上限，接收退出结果后显示断线原因。
- 按用户确认的策略，睡眠期间保留已经建立的 SSH 连接；唤醒后显示未确认可用性的提示，由心跳识别断线，用户决定何时重连。
- 手动重连会等待旧连接、进程与认证任务完成回收，再发起新的认证。
- 新文案进入 String Catalog，当前共 171 个中英双语类型化键。

M2 的会话、分组、SQLite 和 Keychain，M3 的离线终端、设置，以及 M4 的主机信任、真实 PTY 和凭据隔离继续保留。没有实现自动重新认证，也没有恢复原远端 shell 或远端程序的能力。

## 运行与手工验证

先用 ⌘Q 退出旧进程，再在当前工程运行：

```sh
cd /Users/harvey/Documents/github-code/DeckShell
sh Scripts/run.sh zh-Hans
```

无需完整 Xcode 或 Apple Account 登录。应运行打包后的 `DockShell.app`；直接 `swift run DockShell` 不负责资源组装和 helper 签名。

私钥登录：

1. 新建或编辑会话，选择“私钥”，选取用户管理的外部文件。
2. 不把私钥复制到应用目录或数据库。文件移动、失效或无法读取时，重新选择文件。
3. 需要口令时可在编辑器中保存到 Keychain；否则在连接时输入临时口令。临时口令只用于本次连接，不自动补写到 Keychain。
4. 首次连接仍须核对主机 SHA-256 指纹。主机不受信任或发生变化时，不进入私钥口令处理或认证。
5. 连接失败会区分文件不可用、权限不安全、格式不支持、文件损坏、口令问题或服务器拒绝。

agent 登录：

1. 在用户自己的 OpenSSH 兼容 agent 中预先装入目标服务器接受的身份。
2. 会话选择“ssh-agent”，连接时由 agent 完成签名。
3. DockShell 不自动执行加钥、解锁或转发。没有 agent、agent 中没有身份或探测超时，都会显示可读提示。

断线后点击“重新连接”建立新会话。唤醒提示也提供主动重连入口；重连会结束现有本地 SSH 连接，不会恢复旧 shell 的内存状态。需要保存远端长期任务时，应使用服务器上的任务管理方式。

## 分层与新增协议

```text
SSHSessionPane / SSHConnectionPrompts
    │ MainActor 与临时安全输入
    ▼
SSHSessionController
    ├── SSHTransport → OpenSSHTransport
    │     ├── 主机扫描与应用 known_hosts（沿用 M4）
    │     ├── PrivateKeyFileAccess.resolve → 外部书签
    │     ├── PrivateKeyInspecting → PrivateKeyInspector
    │     ├── SSHAgentProviding → OpenSSHAgentProvider
    │     ├── CredentialStore → KeychainCredentialStore
    │     └── 签名 broker / helper → PTYProcessChannel → 系统 ssh
    └── SystemSleepEventSource → MacSystemSleepEvents → NSWorkspace 通知
```

`PrivateKeyInfo` 只传递容器格式和是否需要口令。`SSHAgentIdentity` 只传递本地 socket 与身份数量，不把私钥、公钥备注或 agent 输出暴露给 UI。`SSHKeepalivePolicy` 定义协议级心跳参数，`SystemSleepEvent` 与 `ConnectionRecoveryNotice` 不包含 AppKit 通知类型。

私钥解析、agent 交互、进程和 IO 都留在基础设施层。UI 不读取私钥、不运行 ssh-add，不拼接远端命令，也不根据认证提示文本向终端注入密码。

## 私钥引用、预检与格式范围

会话保存用户批准的外部文件书签。`PrivateKeyBookmarks.resolve` 禁止解析过程自动挂载卷或显示系统 UI，陈旧引用明确报错。

`PrivateKeyInspector` 是容器预检，不是替代 OpenSSH 的密钥实现。它在 Actor 上读取最多 1 MiB，校验文件描述符、容器头尾和有限的长度字段，判断格式与口令需求；解密、完整密钥验证和签名仍由系统 OpenSSH 完成。格式通过预检不等于某台服务器一定接受该密钥。

私钥必须属于当前用户，且没有 group / other 访问权限；常用权限为 0600 或 0400。权限不安全时显示错误，不替用户自动 chmod。预检器会解析文件符号链接，再用 `O_NOFOLLOW` 打开最终文件并检查实际描述符。现有书签入口保留 M2 的普通文件校验，可能拒绝直接选择的符号链接；当前界面请选实际私钥文件，不据预检器能力承诺完整的别名选择支持。

| 容器 | 当前预检范围 | 明确边界 |
|---|---|---|
| OpenSSH 私钥 | `openssh-key-v1`，单把 Ed25519、RSA 或标准 NIST ECDSA；无口令，或已识别的 bcrypt 加密容器 | 系统 OpenSSH 完成实际解密。未知算法、未知 KDF、多密钥或损坏结构会拒绝；不承诺 FIDO / SK 或 DSA 私钥 |
| 老式 PEM | RSA / EC 私钥头；无口令，或支持列表中的传统加密头 | 不承诺所有历史算法或加密方式；系统不接受时显示明确错误 |
| PKCS#8 PEM | 已识别的 RSA / EC 未加密容器，以及 PBES2 加密封装 | 目前仅做结构预检；尚未完成实际解析/登录矩阵，不承诺任意算法或加密变种 |
| PuTTY `.ppk` | 不支持；扩展名和 `PuTTY-User-Key-File-` 文件头都会识别 | 即使改扩展名也不会当作 OpenSSH 私钥。提示通过 PuTTYgen 导出 OpenSSH 格式后重新选择，不新增转换依赖 |

OpenSSH 容器当前识别的加密名称包括 AES CTR / CBC、AES GCM 和 `chacha20-poly1305@openssh.com`；传统 PEM 预检包括 AES CBC 与 `DES-EDE3-CBC`。这些是**私钥文件的静态保护格式**，不表示应用已经为网络握手启用 aes-cbc、SHA-1 RSA 或旧 Diffie-Hellman 兼容选项。

私钥文件内容只在本次检查与系统 SSH 使用期间进入内存，不写数据库、应用副本或日志。口令只在 Keychain 或本次连接内存中保存。系统 askpass 的边界仍为 1–1023 个 UTF-8 字节，不能包含 CR、LF 或 NUL；应用拒绝无法表示的输入，不静默截断。

## 三种认证隔离

M5 继续使用 `-F none`、严格主机公钥校验和应用自有 known_hosts，不读取用户 SSH 配置来隐式改变认证路径。主机身份确认仍先于 Keychain 读取、临时口令请求和 agent 探测。

| 选择的认证 | 明确允许 | 明确关闭 |
|---|---|---|
| 密码 | 仅 password，最多一次 askpass 请求 | publickey、agent、keyboard-interactive、hostbased、GSSAPI |
| 私钥文件 | 仅指定外部 IdentityFile 的 publickey，`IdentitiesOnly=yes` | 密码回退、agent、自动加钥、其他默认私钥与证书 |
| ssh-agent | 指定 agent 的 publickey，`IdentityFile=none`、`BatchMode=yes` | 密码与口令询问、默认私钥文件、自动加钥与 agent forwarding |

用户名、主机和路径使用参数数组或非敏感环境值传递。私钥路径通过 `DOCKSHELL_IDENTITY_FILE`，agent 路径通过 `DOCKSHELL_AGENT_SOCKET` 交给相应 OpenSSH 配置变量，避免路径中的空格等符号重新分词。密码与口令不进入 argv、环境、临时文件或日志。

私钥模式失败不会自动尝试密码，agent 模式失败不会悄悄读取个人私钥。RSA 文件格式或公钥类型名称为 `ssh-rsa`，不等于启用 SHA-1 签名；主机协商仍使用 M4 已批准的算法集合与现代 RSA SHA-2。

## 现有 ssh-agent 的发现

`OpenSSHAgentProvider` 只保留进程环境中的 `SSH_AUTH_SOCK`。GUI 进程没有该值时，允许通过系统 `launchctl getenv SSH_AUTH_SOCK` 查询当前用户的端点，不修改 launchd 环境。

端点必须是本机绝对路径、属于当前用户的 Unix socket。预检使用受限环境运行系统 `ssh-add -l -E sha256`，仅列出已装入的身份；stdout 有上限，诊断和备注不进入用户错误或日志。探测在线程上执行，支持取消、超时和子进程回收。

身份数量大于零只是 agent 可用性预检，不保证其中某个身份已获服务器授权，也不保证硬件或需要用户确认的身份在连接时一定可签名。实际认证由系统 SSH 和 agent 完成；应用不自动处理 agent 的外部解锁或确认窗口。

## READY-only broker

M4 的签名 helper、UID、路径、父 SSH PID、父进程开始时间和随机 nonce 校验继续保留。需要密码或私钥口令时，合格请求最多取走一次秘密数据。

无口令私钥和 agent 使用 `prepare(secret: nil)`：broker 只允许认证后的 `READY` 消息，任何取密码的 `P` 请求都会失败，不能取得空密码、不能消耗凭据，也不能让客户端误判认证成功。`Data()` 仍是非法秘密输入，与 ready-only 模式不同。

认证成功仍由固定 `LocalCommand` 启动签名 helper 的 `--ready` 模式确认；收到输出、banner 或看到进程存活都不能代替认证成功。该机制不添加第三方依赖，helper 的签名和应用打包顺序不变。

## 心跳、断线与睡眠唤醒

生产参数显式设置：

```text
ServerAliveInterval=15
ServerAliveCountMax=3
TCPKeepAlive=no
```

这是 SSH 协议级心跳，不以终端是否输出、鼠标输入或 UI 定时器判断远端存活。静默丢包达到系统 SSH 的无响应上限后，进程退出，通道完成状态映射为心跳超时提示。实际耗时受调度、系统睡眠和具体 OpenSSH 版本影响，不是严格的 UI 倒计时。

用户已选择保留睡眠期间的现有连接：

| 事件与状态 | 行为 |
|---|---|
| 即将睡眠，已经连接 | 保留连接、输入输出任务、终端内容和协议状态，不主动结束远端作业 |
| 唤醒，仍为已连接 | 显示非致命提示，说明可用性尚待心跳判断；不自动断开、不自动认证，可手动重连或关闭提示 |
| 睡眠时正在确认主机或等待密码 / 口令 | 取消该次待认证过程，结束悬挂的用户请求；唤醒后提示用户手动重新连接 |
| 睡眠前已失败、已主动断开或没有会话 | 不凭空发起连接，不覆盖已有失败原因 |
| 心跳或通道后来报告失败 | 保留终端显示，更新断线原因，提供手动重连 |

系统 OpenSSH 没有向应用提供结构化的每次 pong 回调，所以唤醒提示不会声称已确认连接恢复。没有收到输出也不会被 UI 单独当成断线。提示可由用户关闭，真实通道结束会清除该提示并显示对应状态。

`MacSystemSleepEvents` 使用 NSWorkspace 通知，不设置周期轮询。事件值通过有界最新缓冲交给控制器；观察任务取消时移除通知观察者。测试使用独立 NotificationCenter 和注入事件，不让用户的电脑真的睡眠。

手动重连先取消上一代任务，再等待完整 `closeTask` 链：旧通道关闭、旧连接进程回收、待认证任务结束之后才调用新的 transport。快速连续点击产生的中间请求会取消；不会让迟到的旧输出、旧确认答案或旧凭据请求污染新连接。重连会使用当前设置重新建立终端，连接期间字体冻结策略仍沿用 M4。

## 自动验证

默认验证不连接外部服务器，不读取个人私钥或已有 Keychain 项。临时生成的私钥、agent 与秘密仅用于隔离测试，结束后清理：

```sh
sh Scripts/test.sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh release
```

| 检查 | 当前覆盖 |
|---|---|
| M2–M4 回归 | 会话、Keychain 故障流程、SQLite、设置、终端字节与 IME 提交、主机信任、签名 helper、PTY 与资源搬迁 |
| M5 格式与 agent | 临时 OpenSSH / PEM 容器、加密判断、改名 PPK、损坏文件、权限、书签、独立 agent 的有无身份与错误端点 |
| M5 broker | ready-only 永远拒绝凭据请求、合格 READY、错误 nonce / 路径 / 父进程拒绝、合成口令一次性交付和取消清理 |
| M5 transport | 三认证路径隔离、主机信任先于凭据、静态配置、口令来源、没有隐式 fallback、keepalive 参数与友好错误分类 |
| M5 recovery | 活跃连接睡眠保留、唤醒提示、不自动认证、后续超时与手动重连、密码等待取消、连续重连的回收屏障、观察者和控制器释放 |

### 可选真实服务器验证

真实联网检查只在调用者显式提供目标、用户名、外部私钥路径和可信 Ed25519 指纹时执行：

| 环境变量 | 用途 |
|---|---|
| `DOCKSHELL_SSH_TEST_HOST` | 用户授权的服务器；未设置时不运行此检查 |
| `DOCKSHELL_SSH_TEST_PORT` | SSH 端口，省略为 22 |
| `DOCKSHELL_SSH_TEST_USER` | 已授权用户名 |
| `DOCKSHELL_SSH_TEST_KEY_PATH` | 已授权、无口令外部私钥的绝对路径 |
| `DOCKSHELL_SSH_TEST_ED25519_FINGERPRINT` | 通过可信渠道核对的完整 SHA-256 指纹 |
| `DOCKSHELL_SSH_AGENT_TEST=1` | 使用隔离临时 agent 加载这把已授权外部私钥并验证服务器登录；结束后回收，不改变用户现有 agent |
| `DOCKSHELL_SSH_BLACKHOLE_TEST=1` | 额外启用仅供测试的本地 TCP 黑洞转接 |

检查先扫描并比对精确指纹，找不到匹配项则不认证；后续真实握手仍须严格匹配该公钥。使用隔离的临时 known_hosts，不改应用已保存记录或用户 `~/.ssh/known_hosts`。网络测试不读写已保存凭据，也不改服务器认证配置。

无口令私钥检查会建立、读写只读 shell 标记、验证远端行列数并关闭，重复五轮。此路径使用用户批准的现有外部文件，不复制私钥到项目；加密私钥或口令交互应另行验证，不能据此宣布已全部覆盖。

黑洞测试在 loopback 上启动专用转接，仅丢弃**此测试连接**后续数据，让生产 15 秒 / 3 次心跳处理静默丢包。它不修改防火墙、网络接口、路由、真实服务器或其他 SSH 会话。此 C 测试支持目标只链接验证程序，不进入应用。黑洞耗时、退出类别和资源清理由测试记录，不能将一次通过等同于完整网络故障矩阵。

### 可选本地 sshd 集成验证

设置 `DOCKSHELL_LOCAL_SSH_TEST=1` 后，验证器使用系统私有临时目录、临时主机密钥、合成身份和仅限 loopback 的非 root 系统 sshd，验证 OpenSSH、PEM、口令失败与恢复、特殊文件路径和隔离 agent 的真实认证。保留 `StrictModes=yes`，服务端只执行固定 marker，关闭转发。新系统支持时只在此隔离夹具中关闭 `PerSourcePenalties`，避免多次 keyscan / 失败认证被反暴破节流影响；保留严格目录权限和主机校验。不启用系统远程登录，不修改用户或虚拟机的 authorized_keys。最终结果见下方实测记录。

这两类可选集成检查应在构建后对验证器**单独调用一次**，不要将这些环境变量导出给完整 `Scripts/test.sh`，否则默认、UI 与搬迁阶段会重复运行。验证器位置可用公共构建函数查询：

```sh
export DOCKSHELL_ROOT="$PWD"
. Scripts/common.sh
bin_path=$(swift_build -c debug --show-bin-path)
DOCKSHELL_LOCAL_SSH_TEST=1 "$bin_path/dockshell-verify" "$PWD/Build/debug/DockShell.app"
```

## 诊断与进程回收

系统 SSH 的 stderr 仅保留最后 32 KiB 到内存，不写文件、数据库或日志，也不原样显示。长 banner 之后的退出原因仍能保留；每轮限次排空，防止大量诊断阻碍取消与终端数据。心跳超时由 OpenSSH 的 INFO 级消息报告，因此生产固定使用 `LogLevel=INFO`。错误分类使用有限固定模式，主机信任与认证成功仍仅由严格公钥验证和签名 READY 机制决定。

错误私钥口令在当前 Apple OpenSSH 中只在 DEBUG2 提供专用细节，普通诊断可能与服务器拒绝公钥同属认证失败。应用显示“可能是口令错误、系统不支持此密钥格式，或服务器未授权”，不会把凭据已交付当成口令错误的证据，也不为此开启详细调试或增加私钥预解密。真实错误口令必须失败、没有密码回退，并能用正确口令重新认证。[Apple OpenSSH 私钥加载实现](https://github.com/apple-oss-distributions/OpenSSH/blob/main/openssh/sshconnect2.c)

真实快速关闭测试发现 Darwin 可能在退出时等待 PTY master 释放。运行时已改为先关闭 master 和诊断端，再 waitpid；wake pipe 保留到完成发布。正常 EOF 不丢弃已缓冲输出。重连屏障随后等待完整回收，避免后台旧 SSH 卡住。已验证 READY 的记录也会在短命令退出竞态中复查，不能仅以退出码 0 推断认证成功。

## 本轮结果与剩余边界

Recovery 子模块已在 Swift 6、macOS 14 部署目标下独立编译并执行通过，且原 M4 Flow 全回归通过。Debug 与 Release 完整回归均已通过，包含原 M2–M4、M5 认证/恢复、SwiftUI/AppKit 终端、签名和工程外资源搬迁。最终 Release 验证器的可选本地 sshd 集成也已通过：OpenSSH / PEM 无口令及加密登录、错误口令后恢复、凭据引用、特殊私钥路径与隔离 agent 登录。应用和 helper 的严格签名复查通过，Release 两个可执行文件最低系统标记均为 14.0。最终 Release 应用也已重启并用外部 `id_rsa` 登录授权虚拟机。

授权的 Linux 虚拟机已通过应用的外部 `id_rsa` 登录并完成中文交互与手动重连。自动检查完成 5 轮私钥登录、标记回显、远端 91 列 × 13 行窗口同步及完整关闭回收；隔离临时 agent 也完成真实 Linux 登录，未修改用户 agent 或原始密钥文件。生产 15 秒 / 3 次心跳在受控静默黑洞中于 **59 秒**返回 `keepaliveTimedOut`（测试硬截止 75 秒）。这是实测值，不将 UI 计时或 TCP 存活误当成协议响应。

宿主环境仍为 macOS 27 / arm64、Apple Swift 6.4 和 CLT SDK 27。部署目标 macOS 14 不代表已在 macOS 14 实机运行。未为了验证而让本机实际睡眠或修改网络配置。

仍需保留的验收边界：

- macOS 14 实机及不同系统 OpenSSH 版本。
- 真实睡眠、唤醒、网络切换和服务器端空闲断开的组合。
- 中文输入法候选窗口与连续组合的完整实机体验。
- 长时内存、空闲 CPU、多次断线和大输出的性能矩阵。
- 更多历史 PEM / PKCS#8 算法组合，不把扩展名当成全面支持证明。
- Developer ID、公证、双架构分发和稳定签名下的 Keychain 体验。

本轮不宣称 MVP 所有目标环境已经验收；M6 将继续完成环境与性能矩阵。真实密码、私钥内容和口令不出现在本文件或测试结果中。

新版本 OpenSSH 服务器可能对大量预认证扫描或失败认证启用来源惩罚。本地夹具已实际观察到该机制；正式应用不关闭服务器保护，也没有为降低扫描次数而改变已批准的信任与凭据时序。大量快速重连的互操作性留在 M6 继续评估。

## 依赖与构建方式

| 依赖 | 固定版本 / 提交 | SPM 地址或集成方式 |
|---|---|---|
| SwiftTerm | 1.19.0 / `464df5207fc2432e16c9a23abe538187196daf5f` | `https://github.com/migueldeicaza/SwiftTerm.git`，原版 SPM |
| ArgumentParser（上游解析依赖） | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | `https://github.com/apple/swift-argument-parser`，不链接进应用 |
| OpenSSH 工具 | 随目标 macOS | 系统 ssh、ssh-keyscan、ssh-add；测试使用系统 ssh-keygen / ssh-agent / 可选 sshd |
| SQLite、Security、CryptoKit、AppKit、POSIX | 随系统 SDK / macOS | 系统库和框架，没有新增第三方 SPM 依赖 |

没有新增第三方库、个人 fork 或第三方补丁。SwiftTerm 许可证继续随应用资源分发，版本由根 `Package.resolved` 锁定。

当前 CLT 没有 Metal 离线工具，构建脚本继续使用已验证但已弃用的 `--build-system native`。工具链升级仍可能要求重新适配；本轮不以修改上游资源或 manifest 回避该限制。应用和嵌套 helper 当前只使用本地 ad-hoc 签名，不需要 Apple Account。

## 完整文件索引

以下链接指向完整源文件；构建产物不属于源代码交付。原有 M2–M4 文件继续通过历史记录查阅。

| 范围 | 完整文件 |
|---|---|
| 认证元数据与协议 | [SSHAuthentication.swift](../../Packages/DockShellKit/Sources/DockShellDomain/SSHAuthentication.swift) |
| 心跳策略 | [SSHConnectionPolicy.swift](../../Packages/DockShellKit/Sources/DockShellDomain/SSHConnectionPolicy.swift) |
| 睡眠恢复值类型与协议 | [ConnectionRecovery.swift](../../Packages/DockShellKit/Sources/DockShellDomain/ConnectionRecovery.swift) |
| 口令交互与错误 | [SSHInteraction.swift](../../Packages/DockShellKit/Sources/DockShellDomain/SSHInteraction.swift) |
| 外部文件解析边界 | [Ports.swift](../../Packages/DockShellKit/Sources/DockShellDomain/Ports.swift)、[PrivateKeyBookmarks.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/PrivateKeyBookmarks.swift) |
| 私钥容器检查 | [PrivateKeyInspector.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/PrivateKeyInspector.swift) |
| 本机 agent 探测 | [OpenSSHAgentProvider.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHAgentProvider.swift) |
| 系统睡眠通知适配 | [MacSystemSleepEvents.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/MacSystemSleepEvents.swift) |
| 三认证适配与参数 | [OpenSSHTransport.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHTransport.swift) |
| ready-only broker | [OpenSSHCredentialBroker.swift](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHCredentialBroker.swift) |
| C broker 接口与实现 | [DockShellCredentialBroker.h](../../Packages/DockShellKit/Sources/CDockShellPTY/include/DockShellCredentialBroker.h)、[credential_broker.c](../../Packages/DockShellKit/Sources/CDockShellPTY/credential_broker.c) |
| helper 行为 | [Tools/SSHHelper/main.c](../../Tools/SSHHelper/main.c) |
| 连接恢复与回收屏障 | [SSHSessionController.swift](../../Packages/DockShellKit/Sources/DockShellTerminalUI/SSHSessionController.swift) |
| 会话入口与认证提示 | [WorkspaceView.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift)、[SSHSessionPane.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/SSHSessionPane.swift)、[SSHConnectionPrompts.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/SSHConnectionPrompts.swift) |
| 本地化 | [Localization.swift](../../Packages/DockShellKit/Sources/DockShellFeatures/Localization.swift)、[Localizable.xcstrings](../../Localization/Localizable.xcstrings) |
| 依赖组装 | [AppContainer.swift](../../DockShellApp/AppContainer.swift) |
| 验证工程与入口 | [Package.swift](../../Package.swift)、[Verification.swift](../../Tools/Verification/Verification.swift) |
| ready-only / 口令测试 | [M5BrokerVerification.swift](../../Tools/Verification/M5BrokerVerification.swift) |
| 本地完整认证测试 | [M5LocalSSHVerification.swift](../../Tools/Verification/M5LocalSSHVerification.swift) |
| 格式与 agent 测试 | [M5AuthenticationVerification.swift](../../Tools/Verification/M5AuthenticationVerification.swift) |
| 认证、心跳与隔离测试 | [M5TransportVerification.swift](../../Tools/Verification/M5TransportVerification.swift) |
| 唤醒与回收测试 | [M5RecoveryVerification.swift](../../Tools/Verification/M5RecoveryVerification.swift) |
| 可选真实网络测试 | [M5NetworkVerification.swift](../../Tools/Verification/M5NetworkVerification.swift) |
| 仅供验证的 C 网络转接 | [DockShellNetworkTestSupport.h](../../Tools/NetworkTestSupport/include/DockShellNetworkTestSupport.h)、[network_test_proxy.c](../../Tools/NetworkTestSupport/network_test_proxy.c) |
| M4 策略回归适配 | [M4TransportVerification.swift](../../Tools/Verification/M4TransportVerification.swift) |
| 项目状态与交付 | [README.md](../../README.md)、[DockShell-开发方案.md](../../DockShell-开发方案.md)、[本文件](私钥Agent与连接恢复.md) |

本地 sshd 夹具完整文件为 [M5LocalSSHVerification.swift](../../Tools/Verification/M5LocalSSHVerification.swift)。PTY 回收及诊断改动位于 [pty_runtime.c](../../Packages/DockShellKit/Sources/CDockShellPTY/pty_runtime.c)，对应回归为 [M4PTYVerification.swift](../../Tools/Verification/M4PTYVerification.swift)。历史细节见 [M4 密码 SSH 与主机信任](../M4/密码SSH与主机信任.md)、[M3 离线终端与设置](../M3/离线终端与设置.md) 与 [M2 会话与凭据管理](../M2/会话与凭据管理.md)。
