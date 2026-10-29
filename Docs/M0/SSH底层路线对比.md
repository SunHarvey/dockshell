# M0：SSH 底层路线对比与推荐

日期：2026-10-18。用户已认可整体架构，本轮只推进无 UI 的 M0。SSH 后端、正式依赖、fork 与补丁均未获选型批准。

**后续决定（2026-10-27）：用户选择 C：系统 OpenSSH，并批准将持久化改为系统 SQLite。** 本报告的 B 路线推荐保留为当时的技术分析，不代表当前应用选型。当前实现与验证见 [M1 工程基座](../M1/工程基座.md)。

## 1. 推荐

**长期路线优先推荐 B：官方 libssh2 + 自有 Swift 6 协议适配器。最终由用户决定。**

理由是其公开 C API 覆盖密码、私钥、本机 agent、PTY、SFTP 和 TCP 转发，不必依赖个人 Swift wrapper；主机公钥可以在认证前通过结构化 API 验证，便于遵守现有协议分层。相比 Citadel，它没有当前公开 PTY 的 macOS 15 门槛，也无需为所列旧算法先扩展密码实现。

这项推荐有明确代价：项目要维护 C 句柄生命周期、非阻塞状态机、agent 的阻塞隔离、可靠心跳判定，以及 macOS 14 双架构的 crypto 构建。当前 Homebrew OpenSSL 只能用于本机实验，不能随本次结果直接交付用户。

**C：系统 OpenSSH** 是值得保留的备选。如果优先尽快得到成熟的交互终端、agent、心跳和跳板能力，它很有吸引力；图形应用仍需实现安全的 askpass/helper、主机信任及错误分类，第二阶段 SFTP 面板也不应建立在不稳定的命令文本解析上。

**A：原版 Citadel 0.12.1** 当前不作为首选。macOS 14 PTY、agent、背压及心跳均有缺口，AES-CBC 不可用，且已有个人维护的 NIOSSH fork 依赖。满足整个需求的工作范围明显超过降低一个 availability 标记。

以上是“官方实现证据 + 本机离线探针”的工程推荐，不是三条路线均已通过 Linux / macOS 14 端到端验收。

## 2. 评估版本与证据

| 路线 | 本轮版本 | 集成方式 | 证据位置 |
|---|---|---|---|
| A：Citadel | Citadel 0.12.1；传递依赖以 `Probe/Package.resolved` 为准 | 独立 Swift 6 SPM CLI | [路线报告](Citadel.md)、[探针说明](../../M0/Citadel/README.md) |
| B：libssh2 | 官方 1.11.1；实验使用预装 OpenSSL 3.6.3 | 自有 SPM `systemLibrary` / module map，链接隔离构建的官方 C 库 | [路线报告](LibSSH2.md)、[实际输出](../../M0/LibSSH2/Results.txt) |
| C：系统 OpenSSH | 本机 OpenSSH 10.3p1 / LibreSSL 3.3.6；目标 macOS 的版本随系统而定 | 自有 C PTY shim + Swift 6 CLI，执行 `/usr/bin/ssh` | [路线报告](SystemSSH.md)、[探针说明](../../M0/SystemSSH/README.md) |

本机是 macOS 27.0.1 / arm64，Command Line Tools 提供 Swift 6.4 / SDK 27.0，未安装完整 Xcode。各 Swift 验证包声明最低部署目标 macOS 14.0。部署目标、编译成功、当前机器运行成功和目标系统运行成功是四种不同证据。

| 本机验证 | 结果 |
|---|---|
| Citadel 正常探针构建与 inspect | 退出 0；真实接口编入程序，默认不联网 |
| Citadel 独立 macOS 14 负向检查 | 预期退出 1，准确报 `withPTY` 只支持 macOS 15+ |
| libssh2 构建与离线探针 | 退出 0；C 互操作、算法偏好、EAGAIN / 等待 / 唤醒通过 |
| 系统 SSH / PTY 本地自测 | 退出 0；控制终端、尺寸、SIGWINCH、2 MiB 字节校验、临时密钥解析通过 |
| Citadel / 系统 SSH 可执行文件最低版本标记 | 通过 vtool 读取为 minos 14.0；仍不替代目标系统运行 |

Citadel 的本次完整解析图最高要求 Swift tools 6.4（swift-collections 1.7.3）；Xcode 16 只是 Swift 6 语言能力的起点，不是该锁定图的可复现工具链。本机建议安装 Xcode 27.1 正式版，详情见 [环境指引](../开发环境与目录调整.md)。

## 3. 核心对比表

下表的“支持”若无“本机实测”字样，表示官方 API / 源码具备能力，未代表已与真实服务器联调成功。

| 评估项 | A：Citadel 0.12.1 | B：libssh2 1.11.1 | C：系统 `/usr/bin/ssh` + PTY |
|---|---|---|---|
| macOS 14 | manifest 为 14；公开交互 PTY API 为 15+，原版不能直接满足 | C API 无该 PTY 平台门槛；所有 crypto 依赖仍需面向 14 构建和实测 | macOS 14 自带 OpenSSH；自有 PTY 适配仍需在 14 运行验证 |
| 密码认证 | 有 API；真实登录待测 | 有 API；真实登录待测 | 原生支持；Keychain → 签名 askpass helper / IPC 待实现 |
| 私钥与口令 | OpenSSH RSA / Ed25519 路径，格式和 bcrypt / cipher 有限制 | OpenSSH / PEM 能力取决于 crypto、密钥算法及参数；待样例矩阵测试 | 原生 OpenSSH / PEM；本机临时无口令 Ed25519 / RSA PEM 解析通过；加密口令桥接待测 |
| 本机 ssh-agent | 缺现成客户端；同步签名接口阻挡直接 await，需扩展设计 | 官方 Unix agent API；同步阻塞调用需专用执行器，或自有异步 agent + 可重试签名回调 | 原生 agent；独立测试 socket / 身份策略待联调 |
| PTY / resize | API 存在且发送 window-change，但入口要求 15+ | 公开 PTY / shell / resize API；真实远端待测 | 本机 PTY、控制终端、resize 与 SIGWINCH 通过；远端效果待测 |
| 背压 | 原版流为无界 AsyncThrowingStream；只限制下游不够，需调整读取路径 | 本机 EAGAIN / 就绪等待通过；可限制 drain 与 channel window，完整链路仍待压测 | 本机慢消费者 + 2 MiB 逐字节校验通过；真实 SSH 网络及终端渲染链路待测 |
| AES-CBC | 未发现实现；不能用 `.all` 宣称补齐 | 本机算法表与显式偏好接受 aes128/192/256-cbc；远端协商待测 | 本机 `-Q` 有实现，默认未启用，显式配置被接受；目标 14 / 远端待测 |
| group14-sha1 | 有显式兼容实现；协商待测 | 本机列表及偏好配置通过；协商待测 | 本机查询和显式配置通过，默认未启用；协商待测 |
| ssh-rsa / SHA-1 | 有自定义 RSA/SHA-1 路径；现代 RSA-SHA2 路径未确认 | 本机构建同时列出 ssh-rsa 与 rsa-sha2；主机与用户签名均需远端验证 | 本机可显式配置主机及用户 ssh-rsa，默认均未启用；现代 RSA 可使用 SHA-2 |
| SFTP | 有目录及文件 API | 官方 SFTP API，适合协议适配 | 可调用系统 sftp；图形面板需额外结构化协议/进程适配 |
| 本地 / 远程转发 | direct-tcpip 与远程转发基础 API | direct-tcpip 与远程监听/接受 API | 原生 `-L` / `-R`；动态管理需控制进程适配 |
| 动态转发 | 应用实现 SOCKS 层 | 应用实现 SOCKS 层 | 原生 `-D` |
| 跳板机 | 有 `jump(to:)` 基础 | 通道 relay / 自定义 IO 组合第二个 session，需实现 | 原生 `ProxyJump` / `-J` |
| keepalive 心跳失联检测 | 未确认高层应答式入口，需要扩展或额外通道探测 | 有 keepalive 发送 API，缺公开 last-ack/回复计数；可设计同连接 channel 确认探针，仍待故障测试 | 原生 ServerAliveInterval / CountMax；黑洞超时仍待实测 |
| 睡眠唤醒 | 应用检测旧连接并支持手动重连 | 应用检测旧 session、清理后重连 | 应用检测进程/连接并重启；都不保证透明恢复远端 shell |
| 个人 fork | 已依赖 Wellz26 NIOSSH fork；进一步补丁尚未批准 | 不需要个人 wrapper 或 fork；自有薄适配 | 无三方包或 fork，行为随系统 OpenSSH 更新 |
| 主要维护成本 | 多上游补丁、算法、并发与背压回归 | C 状态机、crypto 更新、二进制构建及并发隔离 | PTY/进程、askpass/helper、错误/信任桥接、SFTP 结构化能力 |

依据与具体 API 链接见三个路线报告。RSA 密钥类型不能等同于 SHA-1 `ssh-rsa` 签名算法。查询到旧算法不表示默认启用，也不表示已与旧服务器成功协商。

## 4. 已完成的最小代码验证

### A：Citadel

验证包使用原版 exact 0.12.1，不覆盖源码。正常探针与预期失败的 macOS 14 availability 包分开，避免正常 `swift build` 因负向测试而失败。

正常 CLI 默认不联网，构造认证和严格公钥校验器。另提供用户主动执行的密码、OpenSSH Ed25519 / RSA、PTY / resize 验证入口；不支持的 agent、格式或 macOS 14 PTY 会明确拒绝。

主探针已编译并运行 inspect，退出 0；负向包准确报告 macOS 15 availability 错误。构建、锁定依赖和检查细节见 [Citadel 实际验证记录](Citadel.md#本次验证边界)。未指定测试服务器和可信主机公钥，不自动执行登录。

### B：libssh2

已从官方 tar.gz 构建未修改的 libssh2 1.11.1，并通过 Swift 6 SPM C 模块调用：版本、算法列表、旧算法偏好、session 生命周期、非阻塞 socketpair 握手、EAGAIN、100 ms 内核等待及数据到达后的唤醒。构建运行退出码 0。

自建 libssh2 对象的 minos 为 14.0；**预装 OpenSSL dylib 的 minos 为 26.0**。因此实验产物只证明本机可运行，不能用于 macOS 14 分发。

### C：系统 OpenSSH

已通过 openpty / posix_spawn 的真实本地探针：24×80 → 43×132、控制终端 session、SIGWINCH、暂停消费后 2,097,152 字节逐字节完整性、同路径执行系统 ssh，以及临时无口令 OpenSSH Ed25519 / PEM RSA 解析。构建运行退出码 0。

工具外层权限使 `/dev/tty` 打开返回 EPERM；控制终端 session 和信号验证不受该结果替代，但不能据此宣布交互密码输入通过。正式 App 无沙盒分发与此工具环境不同，仍需实际验证。

## 5. 两项不能省略的实现成本

### libssh2 的 Swift 6 封装与 SPM

M0 的 systemLibrary 只做 C 互操作，不是完整分发方案。正式选择 B 后，建议用固定官方源码构建 macOS 14 的 arm64 / x86_64 静态 libssh2 与获批 crypto 后端，封装 XCFramework，再通过自有 SPM binaryTarget + Swift actor target 集成。不能要求用户安装 Homebrew 库。

同一 session 的 C 指针与 channel 在同一隔离域内管理；EAGAIN 后按 block direction 等待就绪，保持重试参数有效，处理部分写入，加入取消和截止时间。普通 actor 不会让同步 agent 自动异步，相关方案见 [并发与背压说明](LibSSH2.md#swift-6-并发与背压方案)。

其 keepalive API 返回成功不是收到响应。无补丁候选是同一 SSH 连接上至多一个短生命周期 session-channel 打开探针，以匹配到的 OPEN_CONFIRMATION / OPEN_FAILURE 证明对端 SSH 响应；不执行命令、不启动 shell。必须串行关联请求、设绝对截止时间、关闭释放，并处理审计/限流成本；还没有端到端证明满足失联验收。

### 系统 OpenSSH 的产品桥接

密码和私钥口令不能放入 argv、环境变量、临时文件或终端日志。候选方案是签名 askpass helper + 受限本地 IPC；该桥接没有在本轮伪装成已完成。

应用专属 known_hosts 仍必须严格匹配。原生指纹确认需要将候选公钥、用户确认和真实连接验证绑定；单独 ssh-keyscan 不能建立信任。SFTP 二进制协议必须走无 PTY 管道，不能混入终端字节流。

## 6. 私钥格式对比

| 格式 | Citadel 0.12.1 | libssh2 1.11.1 + OpenSSL | 系统 OpenSSH |
|---|---|---|---|
| OpenSSH | RSA / Ed25519；限定 cipher / bcrypt 参数 | 官方后端有解析路径；具体加密样例待测 | 原生；本机无口令 Ed25519 解析通过 |
| 老式 PEM | 本轮选用的 OpenSSH 入口不接受；需另适配 | 官方 PEM 解析路径；受算法 / provider 影响 | 原生解析路径；本机无口令 RSA PEM 通过 |
| PuTTY `.ppk` | 未发现原生解析器，本探针拒绝 | 未发现 PPK 解析入口；Pageant 支持不是 PPK 文件支持 | 不直接读取 PPK |

正式产品需要在格式识别阶段提示具体不支持项，例如“暂不支持 PuTTY PPK 私钥，请使用 PuTTYgen 导出 OpenSSH 格式后重新选择”。测试结果必须细分未加密/加密、RSA/Ed25519、容器和参数；不能概括为所有 PEM 或所有 OpenSSH 都通过。

## 7. 尚未完成的验收与下一步决策

完整清单见 [验收矩阵](验收矩阵.md)。当前尚无 macOS 14 运行环境和指定 Linux 测试服务器，三条路线都不能宣布已经通过密码/加密私钥/agent 登录、远端 resize、网络全链路背压、旧算法协商、心跳黑洞检测或睡眠唤醒。

用户可以依据本报告选择下一条要继续验证/采用的路线，也可以要求先补齐其中某项风险验证。**无论推荐是什么，都不自动进入 M1，不创建 fork，不打补丁。**

## 8. 本轮已确认的产品约束

- 私钥引用用户选定的外部文件，密码和私钥口令保存于 Keychain。
- 单层分组、本机 OpenSSH 兼容 agent、优先验证 OpenSSH Ed25519/RSA。
- 原始字节按序完整处理，滚屏默认 10000 行，可在设置中调整。
- keepalive、睡眠唤醒后的手动重连、私钥格式范围及明确错误提示进入验收清单。
- 统一目标根目录 `/Users/harvey/Documents/github-code/DockShell`，当前目录由用户按 [环境与重命名指引](../开发环境与目录调整.md) 调整。
