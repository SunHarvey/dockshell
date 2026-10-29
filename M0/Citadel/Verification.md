# Citadel M0 验证记录

日期：2026-10-18，Asia/Singapore。

环境：Apple Swift 6.4（swiftlang-6.4.0.34.1），arm64，Command Line Tools，macOS 27 SDK。两个包的最低部署目标为 macOS 14，均为 Swift 6 语言模式。不是 macOS 14 实机运行记录。

| 项目 | 结果 |
| --- | --- |
| `Probe` 编译 | 退出 0，`Build complete! (37.02秒)` |
| `Probe` 默认离线 inspect | 退出 0，显示已构造 `SSHAuthenticationMethod`、`SSHHostKeyValidator` |
| `AvailabilityCheck` 编译 | 预期退出 1，错误为 `withPTY(_:environment:perform:) is only available in macOS 15.0 or newer` |
| Citadel 源码修改检查 | 下载 checkout 的 `git status --porcelain` 为空 |
| 私钥/密码/agent 服务器登录 | 未运行 |
| 真机 macOS 14、resize、旧算法握手、背压/keepalive/睡眠 | 未运行，保持待验证 |

本次成功构建命令从 `M0/Citadel/Probe` 执行；负向检查从 `M0/Citadel/AvailabilityCheck` 执行同一命令，重用临时依赖缓存：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/dockshell-m0-citadel-clang-cache \
SWIFT_MODULE_CACHE_PATH=/tmp/dockshell-m0-citadel-swift-cache \
swift build --disable-sandbox \
  --cache-path /tmp/dockshell-m0-citadel-cache \
  --scratch-path /tmp/dockshell-m0-citadel-build
```

本次离线运行命令：

```sh
/tmp/dockshell-m0-citadel-build/out/Products/Debug/citadel-probe inspect
```

仅依赖下载重试时额外设置了进程级 `http.version=HTTP/1.1`、`http.lowSpeedLimit=1024`、`http.lowSpeedTime=30`。正常开发环境无需这些选项。完整固定版本见两个包各自的 `Package.resolved`；最高工具链要求来自 swift-collections 1.7.3 的 tools 6.4。

主探针没有处理无应答 SSH keepalive，没有模拟 ssh-agent，没有使用丢数据的缓冲来伪造背压。API 编译通过与源码检查只能证明接口存在、平台限制和设计风险，不能证明真实 Linux 登录、终端渲染或性能验收。
