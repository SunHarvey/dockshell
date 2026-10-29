# GitHub Actions 构建与预览发布

DockShell 的云端流程分为 `CI` 和 `Preview Release`。前者编译、运行默认验证并生成可下载的 arm64 DMG；后者在推送 `v*-preview.*` 标签时生成公开的预览 Release，也支持手动为已有版本标签创建草稿。应用的 SSH、终端及会话业务代码不依赖 GitHub Actions。

当前工作流准备的是 **ad-hoc 签名、未公证的测试预览包**。自动发布的版本标为 **Pre-release**，不会设为 Latest。GitHub 提交记录上的 SSH `Verified` 与 macOS 应用的 Developer ID 签名、公证相互独立。

Actions Artifact 和 Release 的安装附件均以 **DMG 原文件**提供：直接下载、打开后将 `DockShell.app` 拖到 `Applications` 快捷方式。DMG 只是包装格式，不会让应用自动获得 Developer ID 签名或 Apple 公证。

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

进入 [Actions 页面](https://github.com/SunHarvey/dockshell/actions)，选择一次 `CI` 运行，可展开各步骤查看环境、编译和验证日志。成功运行后，在页面底部的 **Artifacts** 点击名称以 `.dmg` 结尾的安装包即可直接下载，无需解压 ZIP。日志 Artifact 名称以 `ci-logs-arm64-` 开头，保留 7 天。

默认流程检查发布脚本和 CI 发布参数，再执行：

```sh
sh Scripts/test.sh
```

默认验证使用临时数据与合成连接，不自动开启 GUI smoke、个人 Keychain、真实服务器或性能专项验证。需要图形交互、真实 SSH、实际睡眠等人工验收的范围，继续以 [验收矩阵](M6/验收矩阵.md) 为准。

默认回归后，CI 还会实际构建 Release 预览包与 DMG，检查镜像、映像内应用签名及归档校验值；结果记录在 `dmg-package.txt`，此步骤不创建 Release。

只想试用当前提交时，直接下载成功 CI 运行的 DMG 即可，无需创建版本标签或草稿 Release。工作流使用固定版本 `actions/upload-artifact v7.0.2` 的 `archive: false` 上传单个 DMG，Artifact 名称就是实际文件名；此选项支持[原文件下载](https://github.com/actions/upload-artifact/tree/cf430e030ddbb5b0abf93d22962f4752f3646cd9#upload-an-individual-file-unzipped)。

## 从 Release 下载 DMG

打开 [v0.1.0-preview.2 Release](https://github.com/SunHarvey/dockshell/releases/tag/v0.1.0-preview.2)，在 **Assets** 中点击 `DockShell-0.1.0-16-arm64-local-preview.dmg` 即可下载原文件。公开的 Release 不要求访问者登录具有维护权限的账号，安装附件也不会随 Actions Artifact 的保留期到期。

GitHub 自动生成的 **Source code (zip)** 和 **Source code (tar.gz)** 是源码归档；安装应用请选 `.dmg` 附件。

## 准备版本标签并发布预览

发布工作流要求标签已经存在于远端，且标签指向的提交包含本轮工作流、CI 发布脚本和 DMG 打包代码。工作流不会自动创建、移动或强制覆盖标签。

已经存在的 `v0.1.0-preview.1` 固定到旧 ZIP 打包流程。不要移动该标签或覆盖已有草稿；公开 DMG 预览使用包含新工作流的标签，例如 `v0.1.0-preview.2`。应用版本仍为 `0.1.0 / build 16`，本次仅调整打包与发布流程。

例如，在已包含这些改动的 `main` 上创建当前 `0.1.0` 的预览标签：

```sh
git switch main
git pull --ff-only origin main
git tag -a v0.1.0-preview.2 -m "DockShell 0.1.0 preview 2 (DMG)"
git push origin refs/tags/v0.1.0-preview.2
```

推送匹配 `v*-preview.*` 的新标签会自动运行 `Preview Release`：检出标签、编译、验证、创建 DMG，再创建公开的 **Pre-release**。完成后到 [Releases](https://github.com/SunHarvey/dockshell/releases) 的对应版本 **Assets** 下载 DMG。构建或验证失败时不会发布；同名 Release 已存在时不会覆盖。

如果希望标签也使用当前仓库配置的 SSH 密钥签名，可把 `git tag -a` 改为 `git tag -s`。这使用本机已有的签名配置，云端发布无需导入该私钥。

版本规则：

- 使用 `v主版本.次版本.修订版本`，可带预发布后缀，例如 `v0.1.0-preview.2`。
- 标签的核心版本必须与 [Info.plist](../Packaging/Info.plist) 的 `CFBundleShortVersionString` 一致；当前为 `0.1.0`。
- `CFBundleVersion` 是构建号，当前为 `16`，不会被工作流自动修改。
- 打包时的 `HEAD` 必须就是该标签对应的提交。不存在的标签、分支名、错误版本和不安全输入会被拒绝。
- 工作区必须干净，不能存在未提交修改或未忽略的新文件，确保打包内容与标签对应的提交一致。

准备下一个应用版本时，先修改版本与构建号、提交并检查 CI，再给该提交创建新标签。已有标签或已有 Release 应使用新的版本标签替代，避免混淆同名版本的内容。

## 手动生成草稿 Release

手动入口用于先核对草稿。不要再次对已经公开发布的预览标签运行；工作流会拒绝同名 Release。

1. 确认对应版本的 `CI` 结果，并确保待核对的标签已推送。要预先检查草稿，可使用不匹配自动触发规则的标签，例如 `v0.1.0-rc.1`。
2. 打开 **Actions → Preview Release → Run workflow**。
3. 工作流分支选择 `main`，在 **tag** 中填写完整标签，例如 `v0.1.0-rc.1`。
4. 运行后等待构建、默认验证、产物审计和上传完成。
5. 在本次运行的 **Artifacts** 点击名为 `DockShell-版本-构建号-arm64-local-preview.dmg` 的条目直接下载安装包；也可登录具有仓库权限的账号，到 [Releases](https://github.com/SunHarvey/dockshell/releases) 查看草稿，从 **Assets** 下载同一个 DMG。

手动运行保持 **Draft + Pre-release** 状态；草稿仅供具有仓库相应权限的账号查看。要对外提供下载，需要在 GitHub 页面发布该草稿。标签推送入口则直接创建公开的 **Pre-release**，无需手动发布。两种入口都不会覆盖同名 Release。

发布流程的 Actions Artifact 保留 14 天；Release 附件不受该保留期影响。产物如下，DMG 作为单个原文件上传，校验文件与清单可放在单独的元数据 Artifact 中：

| 文件 | 用途 |
|---|---|
| `DockShell-版本-构建号-arm64-local-preview.dmg` | 只读压缩磁盘映像，包含已签名的 `DockShell.app` 与 `Applications` 快捷方式 |
| `SHA256SUMS` | DMG 的 SHA-256 校验值 |
| `ReleaseManifest.plist` | 版本、构建号、架构与未公证状态 |
| `ReleaseNotes.md` | 预览版本说明与使用边界 |

GitHub Release 的 **Assets** 包含 DMG、校验文件和清单，`ReleaseNotes.md` 用作版本正文。公开的预览版与手动草稿均不会标为 Latest。清单中的 `notarized=false` 和 `publiclyDistributable=false` 表示尚未满足正式签名、公证和分发验收条件，不代表 GitHub Release 的草稿可见性。

**安装只需下载 `.dmg` 条目。** 本工作流在 Actions 中原样上传 DMG，Release 的 Assets 也直接提供 DMG，两种入口都不需要解压应用 ZIP。日志或元数据 Artifact 可能仍是 ZIP，安装时不需要下载它们。

打开 DMG 后，将 `DockShell.app` 拖到 `Applications（应用程序）` 快捷方式，复制完成后推出磁盘映像。当前包依然未公证；系统安全检查与安装包格式相互独立。

需要核对文件时，将 DMG 与对应的 `SHA256SUMS` 放在同一目录；从元数据 Artifact 获取校验文件时，先解压该元数据包。执行：

```sh
shasum -a 256 -c SHA256SUMS
```

SHA-256 验证 DMG 文件完整性，不等于 Developer ID 身份验证或 Apple 公证。当前安装包仍是未公证预览；正式分发的签名、公证入口见 [M6 分发准备](M6/分发准备.md)。

## 本机校验入口

下面命令均在仓库根目录运行。仅验证已有标签与版本，不打包：

```sh
sh Scripts/ci-release.sh validate v0.1.0-preview.2
```

本机已检出该标签、且运行于 macOS arm64 时，可准备同样的预览产物：

```sh
sh Scripts/ci-release.sh prepare v0.1.0-preview.2
```

辅助脚本通过 `release.sh --local-preview --result-file FILE` 获取本次成功构建的精确目录，检查 arm64 应用、源 ZIP 与 DMG 校验值，随后将 DMG 及其校验文件整理到独立的 `Build/ci-release.*` 目录。`release.sh` 内部仍保留 ZIP 供已有审计和后续公证流程使用，但 CI 的安装附件以 DMG 为主，不把应用 ZIP 再套进下载产物。辅助脚本不搜索旧版本目录来猜测待上传文件。

`prepare` 向工作流输出 `artifact_dir`、`dmg_path`、`notes_path`、`manifest_path` 及标签、版本、构建号和源码提交信息；DMG 安装附件的路径字段为 `dmg_path`。

打包使用 macOS 自带的 `hdiutil` 与 `ditto`，不新增第三方打包依赖。DMG 会经过完整性检查、只读挂载，以及映像内应用签名、架构、资源和快捷方式检查。

CI 参数边界可单独验证：

```sh
sh Scripts/test-ci-release.sh
sh Scripts/test-dmg-packaging.sh
```

## 权限与文件索引

普通 CI 和发布构建阶段仅请求 `contents: read`。只有成功构建后的发布任务请求 `contents: write`，使用工作流自带的 `GITHUB_TOKEN` 创建公开预览或手动草稿，不需要个人 Token 或 GitHub SSH 私钥。

当前没有接入 Developer ID 或公证凭据。后续接入正式签名时，应通过受保护的 Actions Secrets 和 runner 临时 Keychain 配置，而不是把证书、密码或 Apple API 私钥提交到仓库。

| 完整文件 | 职责 |
|---|---|
| [ci.yml](../.github/workflows/ci.yml) | 自动编译、默认验证与日志上传 |
| [release.yml](../.github/workflows/release.yml) | 推送预览标签后发布公开 DMG，或手动选择标签创建草稿 |
| [ci-release.sh](../Scripts/ci-release.sh) | 标签、版本、架构校验与精确产物整理 |
| [test-ci-release.sh](../Scripts/test-ci-release.sh) | 临时仓库中的发布参数边界验证 |
| [release.sh](../Scripts/release.sh) | 原生应用、helper、资源、签名和预览归档打包 |
| [package-dmg.sh](../Scripts/package-dmg.sh) | 系统工具创建 DMG，并检查只读挂载后的应用与快捷方式 |
| [test-dmg-packaging.sh](../Scripts/test-dmg-packaging.sh) | DMG 参数保护与可选的真实应用封装验证 |
| [audit-release.sh](../Scripts/audit-release.sh) | 应用架构、签名、资源及部署目标审计 |
| [test.sh](../Scripts/test.sh) | 默认验证和应用搬迁检查 |

工作流仅使用以下 GitHub 官方 Actions，并固定到完整提交 SHA；版本注释也保留在工作流中。没有新增 Swift 应用依赖。

| Action | 版本 | 固定提交 SHA |
|---|---|---|
| [actions/checkout](https://github.com/actions/checkout) | `v7.0.1` | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| [actions/upload-artifact](https://github.com/actions/upload-artifact) | `v7.0.2` | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| [actions/download-artifact](https://github.com/actions/download-artifact) | `v8.0.2` | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |
