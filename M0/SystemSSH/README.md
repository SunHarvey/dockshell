# 系统 SSH / PTY 最小验证

纯 Swift 6 SPM 命令行程序，最低部署目标 macOS 14，无第三方依赖、UI 或联网。完整评估见 [`Docs/M0/SystemSSH.md`](../../Docs/M0/SystemSSH.md)。

目录改名完成后，正常终端执行：

```sh
cd /Users/harvey/Documents/github-code/DockShell/M0/SystemSSH
swift run system-ssh-probe --self-test
```

本次受限工具环境实际使用以下可复现命令（当前目录仍为 DeckShell，执行前先进入 `M0/SystemSSH`）：

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/dockshell-m0-systemssh-modulecache \
    SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/dockshell-m0-systemssh-modulecache \
    swift run --disable-sandbox \
    --scratch-path /private/tmp/dockshell-m0-systemssh-build \
    system-ssh-probe --self-test
```

`--disable-sandbox` 只用于本次嵌套 SPM sandbox 的环境限制；本包没有插件或外部下载。它不会解除工具环境的外层权限。普通终端优先使用第一条命令。

2026-10-18 当前主机验证：Swift 6.4 / Darwin 27 / arm64 / OpenSSH 10.3p1，命令退出码 0。摘要：

```text
PASS：独立 session、控制终端、初始尺寸 24×80
诊断：READY rows=24 cols=80 ctty=1 leader=1 devtty_errno=1
PASS：TIOCSWINSZ 更新为 43×132，子进程收到 SIGWINCH
PASS：消费者暂停后，2,097,152 个原始字节完整且按序；单次读取最多 16 KiB
PASS：系统 /usr/bin/ssh 经 PTY 启动，OpenSSH_10.3p1, LibreSSL 3.3.6
PASS：临时无口令 OpenSSH Ed25519 私钥经系统 ssh-keygen 生成并解析
PASS：临时无口令 传统 PEM RSA 私钥经系统 ssh-keygen 生成并解析
PASS：临时密钥测试目录已清理
```

`devtty_errno=1` 表示本会话权限限制打开 `/dev/tty`；`tcgetsid` 的控制终端校验和 resize 信号测试通过，但不能据此宣称真实交互密码认证完成。当前运行不等于 macOS 14 实测。完整网络认证、Keychain→askpass、远端 PTY、心跳、睡眠唤醒和网络背压均未验证。

自测只启动本地测试 helper、`ssh -V`、`ssh-keygen`。两把临时无口令密钥仅供本地格式解析，生成于随机 0700 目录，不用于认证，不导入 agent，随后删除；没有读取用户密钥或向命令行参数传递秘密。
