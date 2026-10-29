# M0：无 UI 技术验证

日期：2026-10-18。只进行 SSH 底层候选验证；不创建应用 UI，不决定正式依赖，不 fork、不修改第三方源码。

先阅读 [三路线对比与推荐](../Docs/M0/SSH底层路线对比.md)，再查各路线细节和 [验收矩阵](../Docs/M0/验收矩阵.md)。完整 Xcode 安装及目录重命名见 [开发环境与目录调整](../Docs/开发环境与目录调整.md)。

## 环境与证据边界

当前测试环境为 macOS 27.0.1 / arm64，CLT 提供 Swift 6.4 / SDK 27.0。Swift 6 语言能力的起点是 Xcode 16，但当前 Citadel 候选的解析依赖图包含 tools 6.4 的包，不能承诺该锁定图支持 Xcode 16。如选择安装完整 Xcode，当前主机可按官方兼容表选择 27.1 正式版；安装不是现有 M0 SSH 探针的前置条件。

当前 M0 不要求安装完整 Xcode，三条正常 SSH 探针已在 CLT 下构建。后续完整应用的纯 CLT 门槛、SwiftTerm 和 SwiftData 补充验证见 [不安装 Xcode 的构建方案](../Docs/不安装Xcode的构建方案.md)；不能将本轮 SSH 探针通过等同于全部产品依赖可用。

每个验证包声明 macOS 14.0 最低部署目标。编译设置不代表 macOS 14 运行通过；预装 OpenSSL 的最低系统版本更高，libssh2 本机实验产物不能直接用于正式分发。

本轮默认命令不连接服务器，不读取用户现有私钥或访问用户 agent。系统 SSH 自测会生成两把仅用于解析的临时无口令密钥，完成后删除。

## 目录重命名后运行

以下命令按统一目标根目录编写。重命名前，先使用当前 `DeckShell` 路径；不得同时创建两份活动项目。

### 系统 SSH / PTY

```sh
cd /Users/harvey/Documents/github-code/DockShell/M0/SystemSSH
swift run system-ssh-probe --self-test
```

通过标准：控制终端及 session、尺寸变化与 SIGWINCH、2 MiB 逐字节完整性、系统 ssh 启动、临时 OpenSSH/PEM 解析。受限工具环境的缓存参数见 [路线 README](SystemSSH/README.md)。

### libssh2

提供已经安装的 OpenSSL 前缀；脚本不自动安装或修改系统软件。本机预装前缀如下，仅供本机实验：

```sh
cd /Users/harvey/Documents/github-code/DockShell
sh M0/LibSSH2/build-and-run.sh /opt/homebrew/opt/openssl@3
```

脚本下载固定官方 1.11.1，检查本轮记录的 SHA-256，在路线目录内构建。首次执行需要网络；crypto 路径可替换为开发者明确提供的有效前缀。输出应包含版本、算法表、旧算法偏好、EAGAIN、100 ms 超时和就绪唤醒。[完整结果与限制](../Docs/M0/LibSSH2.md)

### Citadel

```sh
cd /Users/harvey/Documents/github-code/DockShell/M0/Citadel/Probe
swift build
swift run citadel-probe inspect
```

另有独立的预期失败包验证公开 PTY 的 macOS 14 可用性限制；正常探针不受其影响。具体命令、最终构建状态及用户主动连接选项见 [路线 README](Citadel/README.md) 和 [路线报告](../Docs/M0/Citadel.md)。

## 完整文件入口

| 路线 | 完整源文件 |
|---|---|
| Citadel | [SPM 配置](Citadel/Probe/Package.swift)、[Swift 探针](Citadel/Probe/Sources/CitadelProbe/Probe.swift)、[锁定版本](Citadel/Probe/Package.resolved)、[负向配置](Citadel/AvailabilityCheck/Package.swift)、[负向源码](Citadel/AvailabilityCheck/Sources/MacOS14AvailabilityFailure/Probe.swift)、[实测记录](Citadel/Verification.md) |
| libssh2 | [SPM 配置](LibSSH2/Package.swift)、[module map](LibSSH2/Sources/CLibSSH2/module.modulemap)、[C 头桥接](LibSSH2/Sources/CLibSSH2/shim.h)、[Swift 探针](LibSSH2/Sources/LibSSH2Probe/Probe.swift)、[构建脚本](LibSSH2/build-and-run.sh) |
| 系统 SSH | [SPM 配置](SystemSSH/Package.swift)、[C 头文件](SystemSSH/Sources/PTYShim/include/PTYShim.h)、[C 实现](SystemSSH/Sources/PTYShim/PTYShim.c)、[Swift 探针](SystemSSH/Sources/SystemSSHProbe/Main.swift) |

M0 的诊断文本仅用于开发验证，不是产品界面。后续产品中所有用户可见文案仍使用 String Catalog。

本地通过只表示对应探针成功，不能代替 Linux 认证、macOS 14、端到端背压、keepalive 黑洞和睡眠唤醒验收。收到用户的路线决定后再安排下一步，不自动进入 M1。
