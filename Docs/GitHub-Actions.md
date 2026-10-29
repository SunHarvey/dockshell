# GitHub Actions 构建与草稿发布

DockShell 的云端流程分为 `CI` 和 `Draft Release`。前者检查代码能否编译并通过默认验证，后者为一个已存在的版本标签生成 arm64 预览包和草稿 Release。应用的 SSH、终端及会话业务代码不依赖 GitHub Actions。

当前工作流准备的是 **ad-hoc 签名、未公证的测试预览包**，不会自动公开发布。GitHub 提交记录上的 SSH `Verified` 与 macOS 应用的 Developer ID 签名、公证相互独立。

## 构建环境

- GitHub-hosted `macos-26`、Apple Silicon / arm64。
- 固定使用 `/Applications/Xcode_26.6.app/Contents/Developer` 中的开发工具；所需版本不存在时让任务失败，避免静默换用另一套工具链。
- Swift Package Manager 按 `Package.resolved` 获取项目依赖，不修改锁定版本。
- 应用部署目标仍为 macOS 14；在 macOS 26 上构建和检查，不代表已经完成 macOS 14 实机或 Intel 验收。

云端使用预装的开发工具，本机仍可沿用现有 Command Line Tools。工作流不会要求把个人 GitHub SSH 私钥、Apple 账号、Developer ID 证书或私钥放入仓库。

## 查看 CI

`CI` 在以下情况下运行：

- 向 `main` 推送提交。
- 创建或更新目标分支为 `main` 的 Pull Request。
- 在 GitHub 的 **Actions → CI → Run workflow** 手动运行。

进入 [Actions 页面](https://github.com/SunHarvey/dockshell/actions)，选择一次 `CI` 运行，可展开各步骤查看环境、编译和验证日志。日志 Artifact 名称以 `ci-logs-arm64-` 开头，保留 7 天。

默认流程检查发布脚本和 CI 发布参数，再执行：

```sh
sh Scripts/test.sh
```

默认验证使用临时数据与合成连接，不自动开启 GUI smoke、个人 Keychain、真实服务器或性能专项验证。需要图形交互、真实 SSH、实际睡眠等人工验收的范围，继续以 [验收矩阵](M6/验收矩阵.md) 为准。

## 准备版本标签

发布工作流要求标签已经存在于远端，且标签指向的提交包含本轮工作流和 CI 发布脚本。工作流不会自动创建、移动或强制覆盖标签。

例如，在已包含这些改动的 `main` 上创建当前 `0.1.0` 的预览标签：

```sh
git switch main
git pull --ff-only origin main
git tag -a v0.1.0-preview.1 -m "DockShell 0.1.0 preview 1"
git push origin refs/tags/v0.1.0-preview.1
```

如果希望标签也使用当前仓库配置的 SSH 密钥签名，可把 `git tag -a` 改为 `git tag -s`。这使用本机已有的签名配置，云端发布无需导入该私钥。

版本规则：

- 使用 `v主版本.次版本.修订版本`，可带预发布后缀，例如 `v0.1.0-preview.1`。
- 标签的核心版本必须与 [Info.plist](../Packaging/Info.plist) 的 `CFBundleShortVersionString` 一致；当前为 `0.1.0`。
- `CFBundleVersion` 是构建号，当前为 `16`，不会被工作流自动修改。
- 打包时的 `HEAD` 必须就是该标签对应的提交。不存在的标签、分支名、错误版本和不安全输入会被拒绝。
- 工作区必须干净，不能存在未提交修改或未忽略的新文件，确保打包内容与标签对应的提交一致。

准备下一个应用版本时，先修改版本与构建号、提交并检查 CI，再给该提交创建新标签。已有标签或已有 Release 应使用新的版本标签替代，避免混淆同名版本的内容。

## 手动生成草稿 Release

1. 确认对应版本的 `CI` 结果，并确保标签已推送。
2. 打开 **Actions → Draft Release → Run workflow**。
3. 工作流分支选择 `main`，在 **tag** 中填写完整标签，例如 `v0.1.0-preview.1`。
4. 运行后等待构建、默认验证、产物审计和上传完成。
5. 在本次运行的 **Artifacts** 下载以 `DockShell-arm64-preview-` 开头的构建产物，或到 [Releases](https://github.com/SunHarvey/dockshell/releases) 查看草稿。

发布工作流会重新检查并构建标签对应的代码。构建或测试失败时不会进入创建草稿的步骤；同名 Release 已存在时不会覆盖其内容。

构建 Artifact 保留 14 天，包含：

| 文件 | 用途 |
|---|---|
| `DockShell-版本-构建号-arm64-local-preview.zip` | 保留 `.app` 目录结构、权限与嵌套签名的应用归档 |
| `SHA256SUMS` | ZIP 的 SHA-256 校验值 |
| `ReleaseManifest.plist` | 版本、构建号、架构与未公证状态 |
| `ReleaseNotes.md` | 草稿说明与预览包使用边界 |

创建的 Release 同时标为 **Draft** 和 **Pre-release**，不会自动成为公开的 Latest 版本。草稿需登录具有仓库相应权限的账号查看；普通访客不能把它当作已发布下载包。GitHub Release 附件包含 ZIP、校验文件和清单，`ReleaseNotes.md` 用作草稿正文。

下载并解压 Actions Artifact 后，在其中包含 `SHA256SUMS` 的目录执行：

```sh
shasum -a 256 -c SHA256SUMS
```

SHA-256 验证归档完整性，不等于 Developer ID 身份验证或 Apple 公证。当前草稿包仍是未公证预览；正式分发的签名、公证入口见 [M6 分发准备](M6/分发准备.md)。

## 本机校验入口

下面命令均在仓库根目录运行。仅验证已有标签与版本，不打包：

```sh
sh Scripts/ci-release.sh validate v0.1.0-preview.1
```

本机已检出该标签、且运行于 macOS arm64 时，可准备同样的预览产物：

```sh
sh Scripts/ci-release.sh prepare v0.1.0-preview.1
```

辅助脚本通过 `release.sh --local-preview --result-file FILE` 获取本次成功构建的精确目录，检查 arm64 应用和归档校验值，随后整理到独立的 `Build/ci-release.*` 目录。它不搜索旧版本目录来猜测待上传文件。

CI 参数边界可单独验证：

```sh
sh Scripts/test-ci-release.sh
```

## 权限与文件索引

普通 CI 和发布构建阶段仅请求 `contents: read`。只有成功构建后的 `publish-draft` 任务请求 `contents: write`，使用工作流自带的 `GITHUB_TOKEN` 创建草稿，不需要个人 Token 或 GitHub SSH 私钥。

当前没有接入 Developer ID 或公证凭据。后续接入正式签名时，应通过受保护的 Actions Secrets 和 runner 临时 Keychain 配置，而不是把证书、密码或 Apple API 私钥提交到仓库。

| 完整文件 | 职责 |
|---|---|
| [ci.yml](../.github/workflows/ci.yml) | 自动编译、默认验证与日志上传 |
| [release.yml](../.github/workflows/release.yml) | 手动选择标签、构建预览包和创建草稿 |
| [ci-release.sh](../Scripts/ci-release.sh) | 标签、版本、架构校验与精确产物整理 |
| [test-ci-release.sh](../Scripts/test-ci-release.sh) | 临时仓库中的发布参数边界验证 |
| [release.sh](../Scripts/release.sh) | 原生应用、helper、资源、签名和 ZIP 打包 |
| [audit-release.sh](../Scripts/audit-release.sh) | 应用架构、签名、资源及部署目标审计 |
| [test.sh](../Scripts/test.sh) | 默认验证和应用搬迁检查 |

工作流仅使用以下 GitHub 官方 Actions，并固定到完整提交 SHA；版本注释也保留在工作流中。没有新增 Swift 应用依赖。

| Action | 版本 | 固定提交 SHA |
|---|---|---|
| [actions/checkout](https://github.com/actions/checkout) | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [actions/upload-artifact](https://github.com/actions/upload-artifact) | `v7.0.2` | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| [actions/download-artifact](https://github.com/actions/download-artifact) | `v8.0.2` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
