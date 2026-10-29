# M0 路线 B：官方 libssh2

核实日期：2026-10-18（Asia/Singapore）。本文件是路线评估，不代表已经选用 libssh2。

## 结论

libssh2 是三条路线中值得优先考虑的长期底层：官方 C API 同时覆盖交互终端、SFTP、SSH agent 和 TCP 通道，不需要依赖个人 Swift wrapper，也不需要为这些能力修改第三方源码。代价是我们需要负责 Swift/C 生命周期、非阻塞状态机，以及加密库的可复现构建和更新。是否采用仍由用户决定。

已完成本机离线探针；没有连接服务器，没有读取用户私钥，没有调用用户 agent，没有 fork 或修改 libssh2 源码。**尚未证明 macOS 14 上的运行、真实服务器认证、远端 PTY 或大流量背压。**

## 版本、来源与构建依赖

- libssh2：**1.11.1**，官方站点当前列出的稳定发布，发布日期 2024-10-16。[官方首页](https://libssh2.org/)、[官方发布记录](https://github.com/libssh2/libssh2/releases/tag/libssh2-1.11.1)
- 官方源码仓库：<https://github.com/libssh2/libssh2.git>；**上游没有原生 SPM Package.swift，因此不能虚构 `.package(url: ..., exact: ...)` 产品。**
- 本轮源码：[官方 tar.gz](https://libssh2.org/download/libssh2-1.11.1.tar.gz)。下载内容 SHA-256：`d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`。脚本使用该值检查重现下载内容；这是本轮 HTTPS 下载后的内容校验，**没有进行官方 PGP 签名验证**。[官方 detached signature](https://libssh2.org/download/libssh2-1.11.1.tar.gz.asc)
- 本机已存在 OpenSSL **3.6.3**，本轮仅利用它完成隔离实验；没有安装 Homebrew 软件。官方仓库为 <https://github.com/openssl/openssl.git>，对应[官方 3.6.3 发布](https://github.com/openssl/openssl/releases/tag/openssl-3.6.3)。它是**当前预装验证依赖，尚未正式选定**。libssh2 的加密后端不是 macOS 自带 CryptoKit，正式选中本路线后还必须批准和锁定一个加密依赖。[官方构建说明](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/docs/INSTALL_CMAKE.md)
- 本轮禁用 zlib 压缩，避免为探针额外增加依赖。libssh2 为 BSD-3-Clause；发布包须保留库和所选加密后端的许可声明。[libssh2 许可证](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/COPYING)

## 最小验证代码及复现

完整代码在 `M0/LibSSH2/`；本机运行输出另存于 `M0/LibSSH2/Results.txt`：

```text
M0/LibSSH2/
├── .gitignore
├── Package.swift
├── build-and-run.sh
└── Sources/
    ├── CLibSSH2/
    │   ├── module.modulemap
    │   └── shim.h
    └── LibSSH2Probe/
        └── Probe.swift
```

构建目录 `.vendor`、`.local`、`.build` 均已排除版本控制。源码下载和编译只写入本探针目录，`make install` 的 prefix 为本目录 `.local`，不会写入 `/usr/local` 或 `/opt/homebrew`。

项目目录重命名后执行：

```sh
cd /Users/harvey/Documents/github-code/DockShell
sh M0/LibSSH2/build-and-run.sh /path/to/existing/openssl-prefix
```

这里的 OpenSSL 路径由开发者明确提供，脚本不自动安装，也不把本机路径写入应用业务代码。本机复现使用了已经存在的 `/opt/homebrew/opt/openssl@3`。

探针实际调用官方 C API：初始化和释放 session、读取编译进库的算法表、配置旧算法偏好，然后在本地非阻塞 `socketpair` 上执行握手。无输入时得到 EAGAIN，使用专用 OS 线程执行有时限的 `poll`，通过 continuation 供 actor 异步等待；写入纯测试 banner 后验证可读就绪并继续握手。它不会假扮完整 SSH 服务端，也不会发送任何用户凭据。

本机结果：

| 检查 | 结果及证据边界 |
|---|---|
| Swift 6 actor + C 模块编译 | 通过；Swift 6.4，arm64，宿主 macOS 27.0.1，Command Line Tools |
| libssh2 版本 | `libssh2_version(0)` 返回 `1.11.1` |
| KEX 算法列表 | 包含 `diffie-hellman-group14-sha1` |
| 主机密钥算法列表 | 包含 `ssh-rsa` 和 `rsa-sha2-256/512` |
| cipher 列表 | 包含 `aes128-cbc`、`aes192-cbc`、`aes256-cbc` |
| 显式旧算法偏好 | `aes128-cbc`、group14-sha1、主机密钥及签名的 `ssh-rsa` 被 `libssh2_session_method_pref` 接受；尚未验证与旧服务器实际协商 |
| EAGAIN / 就绪等待 | 握手返回 EAGAIN，方向为 inbound；无数据等待 100 ms 正常超时；测试 banner 到达后唤醒并重试通过 |
| macOS 14 部署目标 | Swift target 和自建 libssh2 设为 14.0；**现有 OpenSSL dylib 的 Mach-O minos 为 26.0，链接器因此给出警告。本机产物不可交付 macOS 14。** |
| 完整 Xcode 缺失 | 仍可构建 CLI；链接器另提示 CLT 中缺失的 Developer 搜索目录。本轮不宣称完成 App 工程、签名或公证验证 |

列出算法表只证明当前库声明支持，不证明 OpenSSL provider、服务端策略及签名操作全部成功。正式发布必须针对 macOS 14 重建所有 C 依赖，并在 macOS 14 真机或 VM 执行同样及后续端到端检查。

## 能力评估

| 项目 | 判断 | 证据与限制 |
|---|---|---|
| macOS 14 | 可行，待运行验证 | C 库本身没有 macOS 15+ PTY API 门槛；使用 BSD socket，不需要本地 AppKit。依赖二进制须全部以 14.0 为最低目标构建。 |
| 密码认证 | 官方 API 支持 | `libssh2_userauth_password_ex`；keyboard-interactive 是另一种认证方式，不能把所有服务器口令挑战都当作 password。尚未登录验证。 |
| 私钥及口令 | 官方 API 支持 | `libssh2_userauth_publickey_fromfile_ex` / `frommemory`；格式取决于后端和密钥种类，见下表。文件读取和口令派生在主线程外执行。 |
| 本机 ssh-agent | 官方 Unix agent API 支持，有并发注意点 | init/connect/list/get_identity/userauth；读取指定 socket 或 `SSH_AUTH_SOCK`，不需库 fork。见下方关于阻塞的限制。 |
| PTY / 窗口变化 | 官方 API 支持 | `libssh2_channel_request_pty_ex`、`libssh2_channel_process_startup`、`libssh2_channel_request_pty_size_ex`；源码发送 SSH `window-change`。远端 SSH 服务端负责更新 PTY，不由客户端向远端进程直接发送 POSIX 信号。 |
| 背压 | 可控，需正确实现及压测 | session 非阻塞；读写可能短读/短写或 EAGAIN。输出采用按字节计量的有界队列，消费者满时暂停 drain；C 层、TCP 缓冲、SSH channel window 同时计入内存预算。未来多通道需避免一个暂停的通道饿死其他通道。 |
| 旧加密算法 | 本构建 API / 列表支持 | AES-CBC、group14-sha1、ssh-rsa 已见上表。生产默认采用现代算法；如果需要兼容旧主机，应按会话显式配置，不能把 RSA 密钥本身与 SHA-1 `ssh-rsa` 签名混为一谈。 |
| SFTP | 官方 API 支持 | SFTP v3及部分扩展；需按 `SFTPClient` 协议适配。尚未测试服务器互操作。 |
| 本地转发 | 官方通道支持 | 本地监听由应用处理；每条连接使用 `direct-tcpip`。 |
| 远程转发 | 官方请求支持 | `libssh2_channel_forward_listen_ex` / `forward_accept`；本地目的 socket 和生命周期由应用处理。 |
| 动态转发 | 需应用实现 SOCKS | 没有一键 SOCKS 服务器；解析 SOCKS 后复用 `direct-tcpip`。不是额外第三方依赖的必然要求。 |
| 跳板机 | 能组合，非高级现成功能 | 使用第一跳 `direct-tcpip` 作为第二跳字节流，通过自有 relay 或 send/recv 回调承载第二个 session；要独立验证背压、双层主机信任及关闭顺序。 |
| 维护 / 个人 fork | 不需要个人 fork | 维护官方 C 依赖与自有薄适配；持续跟进 libssh2 / crypto 安全修复和双架构构建。自有适配不能掩盖同步 agent 和文件 IO。 |

API 与行为依据：[官方认证 API](https://libssh2.org/libssh2_userauth_password_ex.html)、[官方私钥 API](https://libssh2.org/libssh2_userauth_publickey_fromfile_ex.html)、[agent API](https://libssh2.org/libssh2_agent_connect.html)、[channel.c 的 PTY / 窗口 / window-change 实现](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/channel.c)、[官方非阻塞说明](https://libssh2.org/libssh2_session_block_directions.html)、[头文件通道与转发入口](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/include/libssh2.h)、[SFTP 头文件](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/include/libssh2_sftp.h)。

## Swift 6 并发与背压方案

建议正式实现保持 `SSHTransport`、`SSHSessionChannel`、`SFTPClient` 的协议边界；只有基础设施适配器导入 C 模块。每个 SSH session 和附属 channel 的 C 指针由同一个 actor / 串行执行器持有，禁止在多个任务中同时调用同一 session。跨 actor 只传 `Sendable` 值类型及字节，不把 C 句柄标记 `@unchecked Sendable` 后到处共享。

非阻塞步骤：调用操作 → 成功则推进状态 → EAGAIN 则查询 `libssh2_session_block_directions` → 异步等待读、写或任一方向就绪 → 重试同一操作。重试保持库要求的输入缓冲与参数生命周期；所有等待有取消和截止时间。处理部分写入，消费完一批再继续；不能用 `.bufferingNewest` 丢终端字节，也不能无限制 `AsyncStream`。

**普通 actor 不会把同步 C 调用自动变成异步。** 1.11.1 的 Unix agent 源码注明 agent socket 非阻塞尚未实现，connect / 交互可能阻塞。正式方案有两个可行选择：

1. 为 session actor 配备专用线程执行器，统一串行处理 libssh2 操作和 agent 同步调用，避免占用主线程或 Swift 协作线程；必须补上 agent 超时、取消和关闭边界。线程数可按连接预算控制。
2. 自写异步 Unix agent 协议适配，先取得公钥和签名，再通过 `libssh2_userauth_publickey` 签名回调配合状态机；同步回调与异步签名之间需分阶段调度，不能在回调里直接 `await`，也不能同时操作 session。该路线无需 patch，但实现和验证成本更高。

M0 不替用户决定以上实现选择。探针中的每次 readiness 等待创建专用线程，只用于有界的一次性验证，**不是**生产实现；它最多等待 100 ms，没有立即取消能力。正式使用一个可取消的共享 kqueue reactor，避免每次读取创建线程。

背压需要实际用慢消费者和大输出压测，检查峰值内存及字节顺序。官方 channel 默认窗口为 2 MiB、默认包长 32 KiB，并会随读取调整；这些内部缓冲必须纳入预算，不能仅限制 Swift 层队列就宣称全链路有界。[官方常量](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/include/libssh2.h)、[读窗口实现](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/channel.c)、[agent 阻塞实现](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/agent.c)

## 私钥格式支持范围

下面是官方源码能力，**尚未用生成测试密钥和真实服务器验收**。仍采用用户选定的“引用外部私钥文件，口令存 Keychain”，不会自动读取 `~/.ssh`。

| 文件格式 | libssh2 1.11.1 + OpenSSL 判断 | MVP 应给出的行为 |
|---|---|---|
| OpenSSH `BEGIN OPENSSH PRIVATE KEY` | OpenSSL 后端内有 OpenSSH 解析及 RSA / ECDSA / Ed25519 路径，包含口令解密；具体算法、加密方式及参数仍需样例矩阵验证 | 优先验收 Ed25519 / RSA 的加密和未加密样例；其他变种未验收时不做笼统保证 |
| 老式 PEM，如 `BEGIN RSA PRIVATE KEY` / EC | 走 OpenSSL PEM 解析，有口令解密能力；依赖加密算法 / provider。不能把所有 PKCS#8、DSA 或过时 PEM 加密法都视作已经支持 | 明确区分格式无法解析、算法不支持、口令错误与服务器拒绝，避免全部显示“密码错误” |
| PuTTY `.ppk` v2 / v3 | 没有发现官方 PPK 文件解析入口；代码中出现 PuTTY / Pageant 不等同于读取 PPK 文件 | 在文件格式识别阶段明确提示“不支持 PuTTY PPK 私钥，请先导出为 OpenSSH 格式”；不擅自引入转换依赖或上传文件 |

依据：[OpenSSL 后端 PEM / OpenSSH 实现](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/openssl.c)、[OpenSSH 私钥容器解析](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/pem.c)、[文件认证文档](https://libssh2.org/libssh2_userauth_publickey_fromfile_ex.html)。格式不是扩展名，产品应识别文件头并限制读取大小。PPK 不支持的提示属于计划行为，本探针没有实现文件选择流程。

## keepalive、睡眠与断线

库提供 `libssh2_keepalive_config` 和 `libssh2_keepalive_send`，但它不是替应用完成连接存活判定的后台任务。1.11.1 源码在发送缓冲 EAGAIN 时仍可能返回成功，因此 `keepalive_send == 0` 不能当作已收到远端心跳响应。进一步检查公开头文件、回调集合及 keepalive 实现：**没有公开 API 返回该 keepalive 的响应、响应计数或最后一次有效心跳回复时间**。`want_reply=1` 只是让发出的全局请求要求回复；收到了普通 TCP 数据、socket 可读或发送成功，同样不构成可关联的 SSH 心跳确认。[keepalive API](https://libssh2.org/libssh2_keepalive_send.html)、[实现](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/keepalive.c)、[公开 API / 回调](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/include/libssh2.h)

不打补丁、且确实能观察远端 SSH 协议响应的可行替代，是**同一已认证 SSH 连接上的短生命周期 channel 探针**：

1. 到心跳间隔时，通过公开 `libssh2_channel_open_ex(..., "session", ...)` 打开独立、无 PTY 的 session channel；保持非阻塞、整个 SSH 连接最多一个未完成探针，并使用单调时钟的绝对截止时间。
2. 返回非空 channel 意味着库已经解密、校验并匹配了该 channel 的 `SSH_MSG_CHANNEL_OPEN_CONFIRMATION`；在本版本该操作返回 `LIBSSH2_ERROR_CHANNEL_FAILURE` 则来自匹配的 `SSH_MSG_CHANNEL_OPEN_FAILURE`，同样证明服务器 SSH 层刚刚回复了本次请求。其余本地、解析、传输错误不得计作心跳回复。EAGAIN 只是继续等待，不能计为存活。
3. 成功打开后立即 `libssh2_channel_close`，异步驱动 close / wait_closed / free；不启动 shell、exec 或 subsystem，不向交互终端写命令。若探针始终得不到可关联响应或关闭超过截止时间，将连接标记为“连接无响应”，关闭整个 session 并允许手动重连。不要假称普通超时已经证明具体是网络还是服务器挂起。

这条方案使用标准 channel-open 的确认 / 拒绝作为 SSH 层心跳，既不需要 TCP 可达性冒充心跳，也不需要远端安装程序或执行 `true`。库的 `channel.c` 会按本地 channel ID 匹配响应，因此不是观察“任意网络字节”。即使服务端 MaxSessions / 资源限制拒绝额外 channel，明确的拒绝仍是存活证据。协议依据：[RFC 4254 §5.1](https://www.rfc-editor.org/rfc/rfc4254#section-5.1)；实现依据：[官方 channel-open 状态机](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/channel.c)、[公开 API](https://libssh2.org/libssh2_channel_open_ex.html)。

代价是周期性的 channel 开关和服务器审计记录；某些设备可能限流或不遵守标准回复，需在目标 Linux / 网络设备上验证。调度必须与真实 channel 创建串行，防止污染 libssh2 session 内的 open 状态；因公开 API 没有独立取消未完成 open 的入口，探针整体超时后关闭连接比继续重用半完成 session 更明确。不能把“API / 源码可行”写成已经通过了断网验收。

如采用此探针，不必同时使用 `keepalive_config(..., want_reply: 1, ...)` 获取无法观察的全局响应；可以关闭库自带 keepalive，或仅把 `want_reply=0` 的发包用于保活。真正失联检测必须以可关联的 channel 回复和截止时间为准，TCP 保活只作为辅助。另一种不执行远端程序的方案，是在专用 channel 上用 `libssh2_channel_process_startup` 发一个要求回复的自有未知 channel request，观察返回的 CHANNEL_SUCCESS / CHANNEL_FAILURE；但本版本每个 channel 的该状态机只能完成一次，仍需要轮换 channel，收益不明显。[channel 请求实现](https://github.com/libssh2/libssh2/blob/libssh2-1.11.1/src/channel.c)、[RFC 4254 §5.4](https://www.rfc-editor.org/rfc/rfc4254#section-5.4)

macOS 睡眠 / 唤醒属于应用层生命周期。唤醒后检查旧连接，过期连接清理并提供手动重连；重连重新执行主机公钥校验和认证。用连接代际标识隔离旧任务事件，不能将旧 session 句柄继续当作新连接使用。本轮没有模拟断网或睡眠，不承诺透明恢复远端 shell 状态。

## SPM：本机实验与最终分发的区别

本轮 `.systemLibrary` 只提供 C module map。通过构建参数传入头文件和库搜索目录，它不会自动下载 libssh2 或 OpenSSL，也不会帮用户安装动态库。这适合 M0 验证 C 互操作，**不能将 Homebrew 目录作为官网分发的运行依赖**。

若正式选中 libssh2，推荐由项目维护可复现二进制构建：以官方固定源码构建 arm64 和 x86_64 的 macOS 14 静态 libssh2 及固定 crypto 后端，为同平台合并架构，再生成带公共头文件 / module map 的 XCFramework。用自有 SPM `.binaryTarget` 分发并固定制品校验和，另加自有 Swift actor 包装 target。静态 libssh2 不代表 crypto 也已经静态链接，必须检查最终可执行文件依赖。

补充：上述 XCFramework 制品路线不能在纯 CLT 方案中直接依赖 `xcodebuild -create-xcframework`。用户本机不安装 Xcode 时，可由获批准的完整工具链 Mac 生成制品；完全 CLT 路线则需另评自有 SPM C 模块 + 项目内静态制品及可复现构建脚本，不引入 Homebrew 运行依赖。见 [CLT 构建方案](../不安装Xcode的构建方案.md)。正式后端与 crypto 依赖仍待用户批准。

可以选择随 App 打包动态库并使用 `@rpath`，但要处理各库签名、公证和路径；静态方案减少用户环境依赖，构建和升级责任则由项目承担。本轮没有制作这类分发制品，没有批准后端选择，也未增加个人 wrapper 或包仓库依赖。[Apple 二进制包说明](https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages)

## 未完成的端到端验收

- macOS 14 arm64 / Intel 实际运行，以及所有 C 依赖 minos / 架构检查。
- 测试 Linux 的密码、加密及未加密 OpenSSH / PEM、agent 成功和失败路径；不得把算法列表当登录成功证据。
- PTY 创建、vim / top / htop、连续窗口尺寸变化及 Unicode 原始字节完整性。
- 有界慢消费者、大输出校验、stderr 与多通道公平性、部分写入及取消时释放。
- 显式受限旧算法测试服务端的实际协商，分别测试主机 RSA-SHA1 与用户 RSA-SHA1 签名。
- keepalive 对无响应连接的截止时间、断网、睡眠唤醒后手动重连、主机密钥改变。

以上项目在最终路线获批、具备 macOS 14 环境与专用测试服务器后完成。M0 结论应表述为“API / 源码可行 + 本机离线验证通过”，而非“MVP 已可连接”。
