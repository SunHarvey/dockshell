# Citadel M0 探针

版本：Citadel **0.12.1**，SPM 地址 `https://github.com/orlandos-nl/Citadel.git`。全部依赖为原版下载；没有 fork、补丁或源码替换。

详细结论与证据见 [路线报告](../../Docs/M0/Citadel.md)。本文命令按目录改名后的项目根目录编写；改名前将路径中的 `DockShell` 改为 `DeckShell`。

## 默认离线验证

```sh
cd /Users/harvey/Documents/github-code/DockShell/M0/Citadel/Probe
swift build
swift run citadel-probe inspect
```

`inspect` 构造密码认证对象和严格公钥校验器，报告平台限制。它不联网，不读取私钥，不访问 agent，不请求口令。探针使用 Swift 6 语言模式，最低部署目标 macOS 14。本次 `Package.resolved` 的传递依赖最高要求 **Swift 工具链 6.4**（swift-collections 1.7.3），不能用 Xcode 16 / Swift 6.0 直接复现该锁定图。

## macOS 14 负向编译检查

这是独立的预期失败包，不影响上面的正常构建：

```sh
cd /Users/harvey/Documents/github-code/DockShell/M0/Citadel/AvailabilityCheck
swift build
```

预期错误应指向未经可用性保护的 `withPTY` / `TTYOutput`：macOS 15.0 才可用。仅有其他依赖错误、下载错误或编译器环境错误，不算此项验证通过。

## 可选服务器验证

只能在你主动提供测试主机后手动运行。以下命令不会由开发代理自动执行。`PUBLIC_KEY` 文件应只有经独立可信渠道确认的服务器主机公钥，格式为 `ssh-ed25519 AAAA…` 或支持的 ECDSA 公钥；不是用户公钥，也不是整份 `known_hosts`。这个最小探针尚未接入自定义 RSA 主机公钥解析，遇到 `ssh-rsa` 主机公钥会明确拒绝。

```sh
swift run citadel-probe connect --host HOST --user USER --host-key-file PUBLIC_KEY --auth password
swift run citadel-probe connect --host HOST --user USER --host-key-file PUBLIC_KEY --auth ed25519 --key-file KEY
swift run citadel-probe connect --host HOST --user USER --host-key-file PUBLIC_KEY --auth rsa --key-file KEY --legacy
```

密码和私钥口令从交互终端隐藏读取，不作为参数或环境变量传入，不保存。私钥只读取用户指定路径，不自动扫描 `~/.ssh`。OpenSSH 容器内的 Ed25519 / RSA 解析路径编入程序；旧式 PEM、PuTTY `.ppk` 会给出明确不支持提示。口令的 C 读取缓冲会被擦除；Swift `String` 的运行时副本无法保证原地清零，正式产品需要评估更严格的凭据内存生命周期。

无 `--pty` 时只执行固定的 `printf`，响应上限 64 KiB。macOS 15+ 可加 `--pty`：真实请求 80×24 PTY，发送 120×40 窗口变化，运行 `stty size` 并退出。预期服务器输出包含 `40 120`、中文和 emoji。这只是传输字节检查，不是终端渲染、IME、vim/top 或性能验收。macOS 14 加 `--pty` 时，探针在读取凭据、连接网络之前明确停止。

`--legacy` 仅供隔离兼容性验证，启用 Citadel 的内置兼容算法集合；不能解释为支持 AES-CBC。RSA 探针需要此参数，因为当前 Citadel RSA 实现是 `ssh-rsa` / SHA-1，并未证明 RSA-SHA2 兼容。agent、keepalive、睡眠唤醒、背压性能没有在此 CLI 伪造实现。

## 当前受限环境的构建命令

正常开发环境优先使用上面的普通命令。本次代理运行环境不允许默认用户缓存与嵌套 `sandbox-exec`，因此验证时将缓存放在临时目录，并仅在代理外层隔离已存在的情况下关闭 SPM 的内层沙盒：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/dockshell-m0-citadel-clang-cache \
SWIFT_MODULE_CACHE_PATH=/tmp/dockshell-m0-citadel-swift-cache \
swift build --disable-sandbox \
  --cache-path /tmp/dockshell-m0-citadel-cache \
  --scratch-path /tmp/dockshell-m0-citadel-build
```

上述命令须从 `Probe` 目录执行。依赖下载需要网络权限；不会连接 SSH 服务器。
