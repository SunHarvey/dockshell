# M0 路线 A：Citadel 0.12.1

检查日期：2026-10-18。本文区分源码证据、编译探针和真实服务器验收；没有将“存在 API”记为“已登录成功”。本轮没有创建 fork、没有给任何依赖打补丁，也没有修改下载的第三方源码。

## 结论

**原版 Citadel 0.12.1 不能直接满足 DockShell 的 macOS 14 交互终端 MVP。** 主要缺口是公开 PTY 接口的 macOS 15 可用性标记、缺少成品 ssh-agent 接入，以及输出流缺少端到端消费背压。它有 Swift 异步高层 API、SFTP、直接 TCP 通道和跳板连接基础，但不能把它视为“只补一个系统版本标记就全部可用”的方案。

这是一项路线评估，不是最终选型。是否接受维护 Citadel / NIOSSH 的扩展，应由用户比较三条路线后决定。

## 依赖和维护来源

| 依赖 | 版本或约束 | 地址与说明 |
| --- | --- | --- |
| Citadel | 直接依赖固定 **0.12.1** | `https://github.com/orlandos-nl/Citadel.git` |
| swift-nio-ssh | Citadel 指定 **0.3.4..<0.4.0** | `https://github.com/Wellz26/swift-nio-ssh.git`；这是个人维护的 Apple NIOSSH fork，并非官方 Apple 仓库 |
| swift-nio | Citadel 指定 **>=2.81.0、<3.0.0** | `https://github.com/apple/swift-nio.git` |
| swift-crypto | Citadel 指定 **>=3.12.3、<4.0.0** | `https://github.com/apple/swift-crypto.git`；含内部 BoringSSL C 代码 |
| swift-log | Citadel 指定 **>=1.0.0、<2.0.0** | `https://github.com/apple/swift-log.git` |
| BigInt | Citadel 指定 **>=5.2.0、<6.0.0** | `https://github.com/attaswift/BigInt.git` |
| ColorizeSwift | Citadel manifest 另声明 **>=1.5.0、<2.0.0** | `https://github.com/mtynior/ColorizeSwift.git`；只被 Citadel 示例 executable 引用，不是本探针新增业务依赖 |

完整解析版本以探针的 `Package.resolved` 为准。固定 Citadel 一个版本不会自动固定它全部传递依赖。Citadel manifest 使用 Swift tools 5.9；本项目探针使用 Swift 6 语言模式。依赖自身的语言模式与应用的严格并发检查是两回事。[版本 manifest](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Package.swift)

此次实际锁定版本如下；版本和提交由 `M0/Citadel/Probe/Package.resolved` 保存，工具链要求读取自下载的未修改 manifest：

| 包 | 本次解析版本 | swift-tools-version | SPM 地址 |
| --- | --- | --- | --- |
| Citadel | 0.12.1 | 5.9 | `https://github.com/orlandos-nl/Citadel.git` |
| swift-nio-ssh | 0.3.7 | 5.10 | `https://github.com/Wellz26/swift-nio-ssh.git` |
| swift-nio | 2.104.0 | 6.1 | `https://github.com/apple/swift-nio.git` |
| swift-crypto | 3.15.1 | 5.10 | `https://github.com/apple/swift-crypto.git` |
| swift-log | 1.16.1 | 6.2 | `https://github.com/apple/swift-log.git` |
| BigInt | 5.7.0 | 5.9 | `https://github.com/attaswift/BigInt.git` |
| swift-atomics | 1.3.1 | 5.10 | `https://github.com/apple/swift-atomics.git` |
| swift-asn1 | 1.7.3 | 6.1 | `https://github.com/apple/swift-asn1.git` |
| swift-collections | 1.7.3 | **6.4** | `https://github.com/apple/swift-collections.git` |
| swift-system | 1.8.1 | 6.1 | `https://github.com/apple/swift-system.git` |

**本次锁定依赖图要求 Swift 工具链至少 6.4**，因为 swift-collections 1.7.3 的 manifest 是 tools 6.4。Xcode 16 / Swift 6.0 只是应用采用 Swift 6 的语言下限，不能声称能复现这个锁定图。若需要更老 Xcode，可另做明确的传递版本约束方案并重新测试；本轮不暗中降级，也不修改依赖源码。

## 能力矩阵

| 评估项 | 原版状态 | 对 DockShell 的意义 |
| --- | --- | --- |
| macOS 14 | 包的最低平台是 14；交互 `withPTY`、`withTTY`、`withExec` 和 `TTYOutput` 标记为 15+ | 非交互命令 API 可作为 14 的编译验证；MVP 交互终端被公开 API 限制阻挡，仍须在真实 macOS 14 运行验证 |
| 密码 | 有 `passwordBased` | 支持源码路径；真实登录待测，不能等同 keyboard-interactive / MFA 已支持 |
| 私钥 | 有 Ed25519、RSA 和 ECDSA 认证对象工厂 | 容器解析能力须单列，见下表；RSA 的签名算法不能只看密钥类型 |
| ssh-agent | 有自定义认证 delegate，但没有现成 agent socket 客户端 | 还需枚举密钥、外部签名、取消、超时和签名算法协商；单独实现 delegate 不足以完成 |
| PTY 与尺寸 | `withPTY` 请求 PTY / shell，`TTYStdinWriter.changeSize` 发送 SSH window-change | 可满足协议行为的基础；公开入口有 macOS 15 限制。远端系统把尺寸变化交给 PTY，不能从 API 存在推定 vim/top 验收通过 |
| 背压 | `_executeCommandStream` 创建默认无界 `AsyncThrowingStream`，收到输出直接 `yield` | 下游暂停消费并不会限制该队列。产品中另加有界 actor 不能消除上游无界增长，必须改变读取路径或新增能控制 child-channel 读取的入口 |
| AES-CBC | 检查到 Citadel 的扩展实现是 `AES128CTR`，不是 CBC；NIOSSH 该版本没有检查到 CBC 实现 | 不支持所列 `aes128-cbc` / `aes256-cbc` 旧服务；不能用 `SSHAlgorithms.all` 宣称补齐所有算法 |
| group14-sha1 | 有 `DiffieHellmanGroup14Sha1`，需显式加入算法集合 | 源码路径存在；与服务器强制算法握手仍待测 |
| ssh-rsa / SHA-1 | Citadel 的自定义 RSA 签名和验证使用 SHA-1，签名名前缀 `ssh-rsa` | 可作为旧算法兼容候选；用户密钥认证与主机签名两侧都需单独实测 |
| RSA-SHA2 | 未在该 Citadel RSA 实现中发现 `rsa-sha2-256` / `rsa-sha2-512` 路径 | “支持 RSA 私钥”不等于“兼容现代默认禁用 SHA-1 的 RSA 登录”。不得以 RSA 文件解析成功代替此项验收 |
| SFTP | 有 `openSFTP` 与文件读写、目录操作 | 第二阶段可沿用协议抽象包裹；取消、并发传输、文件大于内存与重连恢复仍需验证 |
| 本地 / 远程转发 | 有 `createDirectTCPIPChannel` 与 `SSHRemotePortForward` 相关 API | 具备基础；本地监听、权限与生命周期由应用实现。动态转发还需 SOCKS 协议层，库没有一键成品客户端面板 |
| 跳板机 | 有 `jump(to:)`，在 direct TCP 通道中建立下一跳 SSH | 架构基础较直接；每跳主机验证、凭据隔离和错误归属需要业务层实现 |
| keepalive | 有断线回调和 TCP channel 关闭检测，未发现高层 SSH 应答式 keepalive API | TCP 关闭检测不能识别所有黑洞断网。应答式心跳与超时机制是待验证扩展点，不能用空写或普通计时器冒充 |
| 睡眠 / 唤醒 | 没有应用级睡眠恢复管理 | 需应用监听系统睡眠/唤醒；唤醒后验证存活、使旧任务失效并明确提示手动重连，不复用旧 shell 对象 |
| 维护风险 | 原版已经依赖个人 NIOSSH fork；Swift 并发边界也需适配 | 若再做产品 fork，会同时承担算法、安全修复、NIO 升级、补丁合并与 macOS 14 回归维护 |

证据来自 [交互流与 PTY](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/TTY/Client/TTY.swift)、[认证工厂](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/SSHAuthenticationMethod.swift)、[算法配置和跳板连接](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/Client.swift)、[AES 实现](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/Algorithms/AES.swift)、[RSA 实现](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/Algorithms/RSA.swift) 和 [底层自定义密钥接口](https://github.com/Wellz26/swift-nio-ssh/blob/0.3.7/Sources/NIOSSH/Keys%20And%20Signatures/CustomKeys.swift)。其中“未发现”的项目是检查该固定版本实现所得的范围结论，不外推到未来版本。

## 私钥格式范围

| 文件 / 容器 | 原版检查结果 | 产品提示与验收要求 |
| --- | --- | --- |
| OpenSSH `BEGIN OPENSSH PRIVATE KEY`，Ed25519 / RSA | 有真实解析入口 `sshEd25519` / `sshRsa`；容器只识别 RSA、Ed25519 | 不能把 ECDSA 认证工厂解释为已支持 OpenSSH ECDSA 容器 |
| 加密 OpenSSH | 识别 bcrypt KDF；cipher 为 `none`、`aes128-ctr`、`aes256-ctr`；代码限制 bcrypt rounds **<32** | 默认常见格式可作为候选；高 rounds、其他 cipher、错误口令需要清晰分类，不能一律提示“密码错误” |
| 老式 PEM，PKCS#1 / PKCS#8 | Citadel 的这条 OpenSSH 解析路径不接受 `BEGIN RSA PRIVATE KEY` / `BEGIN PRIVATE KEY` | 本探针明确拒绝。若要接入 Swift Crypto 或另写转换层，必须另评估格式、算法与加密 PEM 支持，不能当作已支持 |
| PuTTY `.ppk` v2 / v3 | 未发现原生解析器 | 本探针明确拒绝；正式产品提示用 PuTTYgen 导出 OpenSSH 格式。转换工具不是本轮新增依赖 |

见 [OpenSSH 容器解析](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/OpenSSHKey.swift)、[私钥类型检测](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/SSHKeyTypeDetection.swift) 和 [解析公共入口](https://github.com/orlandos-nl/Citadel/blob/0.12.1/Sources/Citadel/SSHCert.swift)。私钥引用用户选择的原文件；本路线没有导入 Keychain 副本。正式产品的密码和私钥口令仍应进入 Keychain。

## 最小兼容方案，仅供审批

以下是工程设计建议，没有创建 diff，也没有执行补丁：

1. **macOS 14 PTY**：先隔离检查 `TTYOutput` 和三个 `with…` 方法是否实际使用了 15-only 能力；其当前逻辑主要封装 `AsyncThrowingStream`。可以提出降低公开可用性标记的最小上游修改，或新增独立 macOS 14 stream 适配 API。必须用 macOS 14 真实机器验证 PTY、关闭、取消、输入和 resize，不能只删除标记即宣布完成。
2. **ssh-agent**：通过 `SSH_AUTH_SOCK` 的 Unix domain socket 实现 identities / sign 协议，遵守 agent 的算法 flag，限制消息长度并处理超时。当前 `NIOSSHPrivateKeyProtocol.signature(for:)` 是同步接口，且 user-auth 消息构造同步取签名。优先提出可异步完成的外部签名入口；不要在 NIO event loop 同步等待 agent，也不要把 agent 私钥导出。这个修改可能涉及 NIOSSH fork，而非只修改 Citadel。
3. **背压**：新增/开放能按需求触发读取的 session channel，设置字节水位并反馈到 NIO child-channel `read` / `autoRead`，验证 SSH channel window 与外层 TCP 读取的关系。替换成会丢弃数据的 bounded `AsyncStream` 不可接受；应支持暂停读取、按序恢复和取消释放。
4. **心跳与旧算法**：需要带应答的 SSH keepalive 入口及截止时间；CBC 若确需支持，属于新增密码实现与测试，不能算“最小 macOS 14 补丁”的附带工作。现代 RSA-SHA2 也需单独设计/验证。

维护代价：每次升级 Citadel、Wellz26 NIOSSH 和 SwiftNIO，都必须检查补丁适用性、并发安全、channel 生命周期和 SSH 协商行为。优先向上游提交可合并变更；未经用户批准不创建产品 fork，不将本设计自动转成实现。

## 本次验证边界

探针源码位于 `M0/Citadel/Probe`，负向编译包位于 `M0/Citadel/AvailabilityCheck`，运行方法见 [README](../../M0/Citadel/README.md)。离线 `inspect` 和编译后的可选 `connect` 是不同证据等级。可选 `connect` 包含真实库调用，不使用空实现替代 PTY 或 agent；未支持的路径会明确停止。

本次使用 Apple Swift **6.4**（`swiftlang-6.4.0.34.1`）、Command Line Tools 和 macOS 27 SDK，主探针的编译目标为 **arm64-apple-macos14.0**。结果：

| 检查 | 实际结果 |
| --- | --- |
| 主 `Probe` 包 `swift build` | **通过，退出 0**。包括真实密码、OpenSSH Ed25519/RSA 构造和 macOS 15 guard 下的 `withPTY` / `changeSize` 调用，最终构建耗时 37.02 秒 |
| `citadel-probe inspect` | **通过，退出 0**；离线构造认证对象及严格公钥校验器，没有访问用户凭据或网络 |
| 独立 `AvailabilityCheck` 包 `swift build` | **按预期失败，退出 1**；错误明确为 `'withPTY(_:environment:perform:)' is only available in macOS 15.0 or newer`，证明 macOS 14 公开入口限制 |
| 下载的 Citadel checkout | `git status --porcelain` 为空；没有修改第三方源码 |

最初默认用户缓存写入及嵌套 `sandbox-exec` 失败，随后缓存迁至 `/tmp`，并在代理已有外层隔离环境下关闭 SPM 内层沙盒。首次 swift-nio 下载停滞后，只为重试进程设置 HTTP/1.1 和 30 秒无进度超时，成功取得原版仓库；没有修改 Git 全局设置。后续构建获得受限环境外编译权限，以避开编译器临时文件写入限制。编译留下 BigInt 的旧 watchOS 平台声明警告，以及 Command Line Tools 缺少 Xcode Developer 搜索路径的链接警告；最终链接成功。这些是当前环境提示，不能用来替代完整 Xcode 的应用构建验证。

尚未执行：Linux 密码/私钥/agent 登录、macOS 14 实机、窗口 resize 的远端效果、慢消费者内存压测、强制旧算法握手、心跳黑洞断网、睡眠唤醒。没有服务器参数和可信主机密钥，因此这些项保持“待实测”，不标通过。
