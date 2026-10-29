# M0 路线 C：PTY + 系统 `/usr/bin/ssh`

验证日期：2026-10-18（Asia/Singapore）。本文件只评估候选路线，不代表选型获批。

## 结论

该路线无需三方运行时依赖或个人 fork，密码、私钥、agent、交互 PTY、端口转发和跳板机具有成熟基础。主要代价是：进程退出、认证提示、主机信任与错误输出不是稳定的结构化 API；图形 SFTP 文件面板不能直接将 `sftp` 文本命令当作 SDK。若优先保证长期原生业务控制与文件面板，需将这些适配成本纳入和库路线的比较。此处没有启动真实服务器连接，也没有实现 Keychain→askpass。

## 本轮实际证据

当前主机为 Darwin 27 / arm64，Command Line Tools 提供 Swift 6.4，`/usr/bin/ssh -V` 为 `OpenSSH_10.3p1, LibreSSL 3.3.6`。SPM 包声明 `.macOS(.v14)`、Swift 6 模式，已在当前主机编译运行。这不能替代 macOS 14 实机验收。

`M0/SystemSSH` 不含三方依赖、网络访问或 UI。自有小型 C shim 封装 POSIX 调用；Swift actor 管理验证任务，阻塞 POSIX 调用放在专用线程，未阻塞主线程或 Swift 合作线程池。测试完成后线程退出。生产版仍需取消、安全关闭与多会话 IO 调度设计。

已通过的本地测试：

| 项目 | 结果及边界 |
| --- | --- |
| 真实 PTY | `openpty`，初始 24 行 × 80 列，原始模式，无 shell 拼接 |
| 子进程生命周期 | `posix_spawn` 创建独立 session；新启动的 helper 用 `TIOCSCTTY`、`tcsetpgrp` 后 `execve` 目标程序；没有 fork 后执行 Swift |
| 控制终端 | 子进程 `tcgetsid(stdin) == getsid(0)`、`getsid(0) == getpid()`，均为真 |
| 当前执行环境限制 | `open("/dev/tty")` 返回 `EPERM`（输出 `devtty_errno=1`）；控制终端 session 与信号测试有效，但不能宣称交互密码输入已验收 |
| 窗口变化 | master 上 `TIOCSWINSZ` 更新为 43 × 132；子进程查询尺寸一致，且收到 `SIGWINCH` |
| 原始字节 | 暂停消费者 150 ms 后读取 2,097,152 字节，包含所有 0…255 值；逐字节验证完整且顺序一致，单次读取最多 16 KiB |
| 系统 SSH 启动 | 通过相同 PTY/helper 路径执行 `/usr/bin/ssh -V` 并成功回收子进程 |
| 私钥格式 | 仅在临时 0700 目录生成无口令 OpenSSH Ed25519、传统 PEM RSA；系统 `ssh-keygen -y` 均成功解析，目录随后清理。未读取用户私钥，未把秘密放入参数或环境 |

大输出测试验证本地 PTY 的有限内核缓冲及无丢字节消费。没有测量内核缓冲容量、RSS 或 CPU，也未验证 SSH 通道、远端 TCP 及终端渲染的完整背压链路。生产版必须在终端高水位停止 PTY 读取，低水位恢复；不得将读取事件转存到无界 `AsyncStream`。默认 10000 行滚屏历史限制与网络字节完整处理是不同层面的约束。

## macOS 14 与认证

Apple 的 Sonoma 14 安全说明列出 OpenSSH 9.3p2，证明该系统自带 OpenSSH，但具体小版本和修订会随系统更新变化。目标 macOS 14 机器仍须运行本探针及算法查询；不把当前 10.3p1 的结果套用到旧系统。[Apple Sonoma 14 安全说明](https://support.apple.com/en-hk/120950)

密码、私钥文件和本机 OpenSSH 兼容 agent 均是 OpenSSH 的原生认证能力；本机 agent 使用 `SSH_AUTH_SOCK`，并不要求打开 agent forwarding。参数数组应明确传入 host、port、username，生产版按认证类型约束 `PreferredAuthentications` 和 identity，避免偷偷读取用户的其他身份。隔离配置建议从 `-F none` 开始，私钥使用用户已批准的文件引用。[OpenSSH ssh 手册](https://man.openbsd.org/ssh)

密码和私钥口令从应用自有 Keychain 取出后，推荐通过签名的 askpass helper 和受限本地 IPC 提供给 ssh：`SSH_ASKPASS` 只包含 helper 路径，`SSH_ASKPASS_REQUIRE=force` 强制使用 helper；IPC 使用每次连接单独的请求标识、进程身份校验及一次性响应，不把秘密放在 argv、环境变量、磁盘临时文件或日志，也不靠匹配终端上的英文 `password:` 来注入。helper 的 stdout 是给 ssh 的私有响应管道，不可接入应用日志。Apple 的实现支持该 askpass 流程，但提示语仍是文本，混合认证、键盘交互和多跳凭据映射需要专门验证；本 M0 未实现此桥接。[Apple readpass.c](https://github.com/apple-oss-distributions/OpenSSH/blob/main/openssh/readpass.c)

私钥引用方案意味着文件移动后需要用户重新选择；Keychain 只存密码和口令，不复制用户私钥。格式范围不能只看扩展名：

| 格式 | 此路线能力与本轮范围 | 产品应给出的提示 |
| --- | --- | --- |
| OpenSSH 私钥 | 原生支持；本轮无口令 Ed25519 生成/解析通过。加密 Ed25519/RSA 及 Keychain→helper 待联调 | 区分错误口令、文件不可读和不支持的算法 |
| 老式 PEM | OpenSSH 私钥解析失败时可回退 PEM；本轮无口令 RSA PEM 通过。不能据此承诺全部 PKCS#8、所有加密方式或所有旧算法 | “此 PEM 的算法或加密方式暂不支持，请转换为 OpenSSH 格式后重试。” |
| PuTTY `.ppk` | OpenSSH 不直接读取 PuTTY 专有私钥格式；MVP 不增加转换依赖 | “暂不支持 PuTTY PPK 私钥，请使用 PuTTYgen 导出 OpenSSH 格式后重新选择。” |

OpenSSH/PEM 回退依据：[Apple sshkey.c](https://github.com/apple-oss-distributions/OpenSSH/blob/main/openssh/sshkey.c)。PPK 转换依据：[PuTTY 官方手册 8.2.15](https://www.puttyssh.org/0.83/htmldoc/Chapter8.html#puttygen-conversions)。识别头部只能用于友好错误分类，不能代替完整密钥解析。

## 窗口、心跳、睡眠唤醒

生产路径是 UI 产生行列尺寸→本地 PTY 的 `TIOCSWINSZ`→ssh 收到 `SIGWINCH`→远端 SSH `window-change` 请求。Apple 客户端源码实现窗口变化的通道消息；本轮只实测到本地信号，vim/top/htop 的远端布局仍待 Linux 测试。[Apple clientloop.c](https://github.com/apple-oss-distributions/OpenSSH/blob/main/openssh/clientloop.c)

可用 `ServerAliveInterval=15` 与 `ServerAliveCountMax=3` 做协议级心跳，通常在约 45 秒无响应后退出；默认 interval 为 0，不能忘记显式配置。应用要区分用户断开、远端退出、心跳超时和睡眠导致的可疑连接。监听系统睡眠/唤醒，在唤醒后检查子进程与连接状态，允许手动重新建链；不能保证既有 TCP/SSH 会话可恢复，也不能在未获确认时新增自动重连策略。用单调时钟处理计时，避免睡眠时把 UI 定时器误当作网络存活证据。[OpenSSH 心跳配置](https://man.openbsd.org/ssh_config#ServerAliveInterval)

## 旧算法：编译能力与默认启用分别判断

当前机器离线执行 `ssh -Q cipher`、`ssh -Q kex`、`ssh -Q key`：

| 算法 | 当前 `-Q` 结果 | `ssh -G -F none probe.invalid` 默认结果 | 显式追加后的离线配置 |
| --- | --- | --- | --- |
| `aes128-cbc` / `aes192-cbc` / `aes256-cbc` | 均存在 | Ciphers 均未启用 | `Ciphers=+aes128-cbc` 被接受 |
| `diffie-hellman-group14-sha1` | 存在 | KexAlgorithms 未启用 | `KexAlgorithms=+diffie-hellman-group14-sha1` 被接受 |
| `ssh-rsa`（SHA-1 签名） | key 查询存在 | HostKeyAlgorithms / PubkeyAcceptedAlgorithms 均未启用 | 两项分别 `+ssh-rsa` 被接受 |

RSA 密钥并不等于必须使用 SHA-1：可以用 `rsa-sha2-256/512`。旧算法应是未来每会话显式兼容设置，不应全局降低默认安全配置；本轮没有新增设置功能。查询和 `-G` 仅证明本机程序具备算法及接受配置，不证明与特定旧服务器成功协商。不同 macOS 补丁、FIPS 策略和目标服务器都可能改变结果。[OpenSSH 旧算法说明](https://www.openssh.org/legacy.html)

## 第二阶段支撑与维护成本

`-L` / `-R` / `-D`、`ProxyJump` / `-J` 已由系统客户端提供；新建与动态管理转发的结构化状态仍需进程及控制 socket 适配。多跳时须分别绑定每跳主机信任与凭据，不能把最终主机的认证策略直接套给跳板机。[OpenSSH 转发和跳板参数](https://man.openbsd.org/ssh)

SFTP 有两个方向：系统 `sftp` 子进程可用于批量传输，但命令/列表输出是文本，不适合直接承诺稳定的文件模型、取消与进度；另一方向用无 PTY 的 `ssh -s sftp` 管道，自有实现 SFTP 二进制协议。后者对图形面板更可控，工作量明显增加。不要将 SFTP 二进制数据放在终端 PTY 中。[OpenSSH SFTP 手册](https://man.openbsd.org/sftp)

主机信任可使用应用专属 `UserKnownHostsFile`，并保持 `StrictHostKeyChecking=yes/ask`。原生指纹确认 UI 的难点在于 ssh 没有给业务层稳定的握手公钥回调：askpass 的确认提示和 stderr 是文本。可考虑先获取候选公钥，让用户确认后将该公钥固定到应用 known_hosts，再启动严格校验的真实 ssh；单独的 `ssh-keyscan` 输出本身不构成信任证据，且第二次握手必须严格匹配。不能为简化 UI 使用 `StrictHostKeyChecking=no`。这一设计需要后续安全与竞态测试。[OpenSSH 主机校验配置](https://man.openbsd.org/ssh_config#StrictHostKeyChecking)

系统路线不维护 SSH 加密实现或个人 fork，也不需要通过 SPM 引入 OpenSSH。维护成本转移至：系统版本矩阵、进程/PTY 生命周期、可取消 IO、helper 签名与凭据 IPC、稳定错误归类、SFTP 协议及控制 socket。系统 SSH 随 OS 更新，应用无法用 Package.resolved 固定其实际版本；启动时应记录非敏感版本能力，不能把终端流或认证提示原样记日志。

## 复现

用户完成目录重命名后，在项目根运行：

```sh
cd /Users/harvey/Documents/github-code/DockShell/M0/SystemSSH
swift run system-ssh-probe --self-test
/usr/bin/ssh -V
/usr/bin/ssh -Q cipher
/usr/bin/ssh -Q kex
/usr/bin/ssh -Q key
/usr/bin/ssh -G -F none probe.invalid
```

`-Q`、`-G` 与本自测均不连接 `probe.invalid` 或任何服务器。默认自测会生成并清理两把仅供解析验证的无口令临时密钥，不将其输出、导入 agent 或用于认证。

本次受限执行环境为了避开不可写用户缓存和嵌套 SPM sandbox 限制，使用以下命令。`--disable-sandbox` 只关闭 SPM 自身的嵌套 sandbox，不会绕过本会话外层文件/网络权限；包没有插件、下载或第三方依赖。用户正常终端无需该参数。

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/dockshell-m0-systemssh-modulecache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/dockshell-m0-systemssh-modulecache \
    swift run --disable-sandbox \
    --scratch-path /private/tmp/dockshell-m0-systemssh-build \
    system-ssh-probe --self-test
```

尚待真实环境验证：macOS 14、Linux 密码/加密私钥/agent 认证、首次及变化指纹、远端窗口更新、网络背压、keepalive 黑洞超时、睡眠唤醒手动重连、真实终端渲染与 IME。本轮没有 fork 或修改第三方源码。
