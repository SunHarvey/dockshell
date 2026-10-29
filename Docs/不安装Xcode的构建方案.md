# DockShell：不安装完整 Xcode 的构建方案

- 日期：2026-10-18
- 状态：2026-10-27 已授权并开始纯 CLT 的 M1 工程基座
- 当前工具链：Command Line Tools，Apple Swift 6.4，macOS 27 SDK
- 应用最低系统：仍为 macOS 14.0
- SSH 后端：2026-10-27 用户已选择系统 OpenSSH

**2026-10-28 M3 更新：** 已使用原版 SwiftTerm 1.19.0 接入离线终端；公共脚本显式选择 native 构建，动态打包其资源。Debug / Release 与终端适配器检查通过。该选项已弃用，且原版字体变更存在模式软重置限制，均记录在 [M3 文档](M3/离线终端与设置.md)。后续旧记录描述当时验证状态，不代表当前尚未接入。

**M2 当前进展：** 已实现 SQLite 会话与分组持久化、Keychain 凭据管理和失败恢复；Debug / Release 与真实 Keychain 检查通过。当前运行和完整文件见 [M2 文档](M2/会话与凭据管理.md)。SDK 的 State 宏缺口通过自有类型别名选择系统既有属性包装器解决，未修改 SDK 或第三方源码。

**2026-10-27 实施更新：** 用户批准会话持久化改用系统 SQLite，替代原 SwiftData 约束。本轮已开始 M1：SwiftPM 分层应用、自有受限 Catalog 编译器、标准 `.app` 打包与本地临时签名。实际入口见 [README](../README.md) 和 [M1 工程基座](M1/工程基座.md)。下文的宏插件、Metal 与候选路线记录保留为历史技术证据；其中“未授权进入 M1”“存储待选择”等表述只描述当时状态，以本段最新选择为准。

**2026-10-19 补充：用户要求完全不登录 Apple ID / Apple Account，而非仅不登录 App Store。** 需账号的官网下载与 xcodes 路线均不符合当前条件；不存在已验证的匿名下载渠道时，不能继续将这些工具作为免账号方案。当前已安装的 CLT 可继续使用，持久化等技术约束仍未经批准不得更换。

## 1. 结论与可选范围

当前 M0 的三路线 SSH 命令行探针可以继续使用已有 CLT。

**不能将“CLT 可以编译 Swift”推导为“当前 CLT 已能完成全部原定 MVP”。**本轮补充验证发现：

1. 普通 SwiftUI / AppKit / SwiftData 符号可通过类型检查，但 SwiftData `@Model` 缺少宏实现插件，最小模型编译失败。
2. 原版 SwiftTerm 1.19.0 在默认 `swiftbuild` 下因找不到 `metal` 失败；显式使用已弃用的 `native` 构建方式后，最小无 UI 探针可编译、链接和运行。
3. 图标、本地化、资源搬迁和应用打包需要自有构建流程，不能只运行 `swift build` 后改一个文件扩展名。

因此，应先区分以下路线，由用户决定：

| 方案 | 保留全部原技术约束 | 本机是否安装 Xcode | 取舍 |
|---|---|---|---|
| **A：本机 CLT，完整应用交给另一台完整 Xcode 的 Mac 构建** | 是 | 否 | 可继续使用 SwiftData、String Catalog 和标准资源编译；需要一台可用构建机及安全交付流程。尚未连接或创建任何构建服务。 |
| **B：所有构建环境都只有 CLT** | 当前未证明可满足 | 否 | SwiftData 宏缺口尚未解决；SwiftTerm 暂依赖弃用构建方式。若改用系统 SQLite 或程序化 Core Data，必须另获用户批准，不能擅自替换 SwiftData。 |
| C：通过账号登录官网下载 `.xip` 安装完整 Xcode | 是 | 是 | **不符合用户免 Apple ID 登录条件，不作为当前推荐**。有可信的既有原版安装包可另评本地安装，不能假定包已存在。 |

若“不安装”只指用户本机，优先推荐 A，保留原需求。若要求任何地方都不能使用完整 Xcode，目前 B 是有阻断项的技术候选，不能作为已经具备交付条件的承诺。

## 2. 本轮实际验证

所有额外探针仅写入临时目录，不创建产品窗口、数据库或 M1 工程，不修改第三方源码。

| 检查项 | 实际结果 | 证据边界 |
|---|---|---|
| Swift 6 / macOS SDK | 已有 Swift 6.4 / SDK 27.0 | 编译宿主为 macOS 27.0.1 / arm64，不能代替 macOS 14 运行验证 |
| SwiftUI、AppKit、SwiftData 普通符号 | `swiftc -typecheck` 退出 0 | 只验证导入和普通类型，不证明窗口、持久化或 UI 运行 |
| SwiftData `@Model` | 原始 swiftc 与 native SwiftPM 最小构建均失败，找不到 `SwiftDataMacros.PersistentModelMacro` | 本机 CLT 目录未找到 SwiftDataMacros 插件；不是数据库运行时错误 |
| SwiftTerm 1.19.0，默认构建方式 | 失败：`unable to spawn process 'metal' (No such file or directory)` | 原版 package 的 `Shaders.metal` 处理触发离线 Metal 编译 |
| SwiftTerm 1.19.0，显式 native 构建 | 编译通过，运行输出 `SwiftTerm import compiled` | 只 import 库，不创建终端 UI；native 已弃用，工具提示未来会移除 |
| SwiftTerm 源码完整性 | 官方 tag，提交 `464df5207fc2432e16c9a23abe538187196daf5f`；checkout 干净 | 没有 fork、补丁或改依赖 manifest |
| Swift Testing | 默认构建的最小测试遇到 TestingMacros 加载错误；native 构建未找到 Testing 模块 | CLT 中实际存在 TestingMacros 文件，但当前命令未形成可运行测试链路；额外搜索/加载参数仍待验证，不将其列为原理上不可能 |
| 打包与签名工具 | `plutil`、`iconutil`、`codesign`、`notarytool`、`stapler`、`lipo`、`dsymutil` 均找到 | 工具存在不等于签名身份、账户、公证和双架构发行已验证 |
| 缺少的工具 | `actool`、`xcstringstool`、`metal`、`metallib` 未找到 | 需要下述替代构建设计或完整工具链构建机 |

### SwiftData 门槛

Apple 的 `@Model` 在构建时展开模型所需实现。本机 SDK 的声明引用外部模块 `SwiftDataMacros`；仅能导入 `SwiftData.framework` 不代表插件存在。

实际错误：

```text
external macro implementation type 'SwiftDataMacros.PersistentModelMacro'
could not be found for macro 'Model()'; plugin for module 'SwiftDataMacros' not found
```

本轮没有找到 Apple 官方独立下载 SwiftDataMacros 的方式，不能编造 SwiftPM 地址，也不能声称所有未来 CLT 都不可能支持。增加 `-sdk` / `-F` 参数无法凭空提供缺失的插件。不以手写宏展开或临时复制不匹配的插件作为已支持方案。

依据：[Apple Model() 文档](https://developer.apple.com/documentation/swiftdata/model())。

## 3. 无 Xcode IDE 的工程组织候选

仅在用户选择并解决上述门槛后实施。MVVM、SwiftUI/AppKit、协议边界、Keychain 和 macOS 14 目标保持不变。

```text
DockShell/
├── Package.swift                         # App executable 与本地分层包依赖
├── DockShellApp/                         # SwiftUI @main 与依赖组装
├── Packages/DockShellKit/                # 领域、业务、基础设施、UI 适配
├── Localization/                         # 唯一人工维护的本地化源
│   ├── App/Localizable.xcstrings
│   └── Features/Localizable.xcstrings
├── Tools/CatalogCompiler/                # 自有 Swift 构建工具，尚未实现
├── Packaging/
│   ├── Info.plist
│   ├── DockShell.entitlements
│   └── DockShell.iconset/
├── Scripts/
│   ├── check-environment.sh
│   ├── build.sh
│   ├── test.sh
│   ├── package-app.sh
│   └── sign-and-notarize.sh
├── M0/
└── Docs/
```

以上是候选目录，不代表已经创建这些产品文件。生成资源与 `Build/`、`.build/` 输出不作为人工维护源，不要求 `.xcodeproj` 参与纯 CLT 构建。

构建过程：检查工具链与依赖 → 验证/生成本地化资源 → SwiftPM 编译 → 组装标准 `.app` → 检查可搬迁性 → 调试签名或获批准的 Developer ID 签名、公证。

构建机方案 A 也可以使用命令行完成流程，但其实际依赖是完整 Xcode 工具链；不能称为所有环节都仅依赖 CLT。

## 4. String Catalog 的受限构建方案

原要求保留：所有产品用户可见文案仍以 `.xcstrings` 为唯一人工维护源，支持 `en`、`zh-Hans`，不另维护一份容易漂移的手写 `.strings`。

缺少 Apple `xcstringstool` 时，可提出一个自有 Swift 命令行转换器：读取已验证的 Catalog JSON，输出系统运行期可读取的 `.strings` / `.stringsdict`，再由 SwiftPM 或打包脚本放入对应 `.lproj`。

建议首版明确支持：

- 普通字符串、引号、反斜线、换行和 Unicode。
- 验证过类型、数量、位置的格式占位符。
- 单一整数变量的复数：英文 `one` / `other`，中文 `other`，使用系统 `.stringsdict` 规则。
- 显示名、菜单、状态、错误、无障碍说明；必要的应用元数据输出 `InfoPlist.strings`。

未知 Catalog 版本、设备/宽度 variation、嵌套 variation、多变量 substitution、不支持的占位符、缺译、未完成翻译和键冲突必须使构建失败。不能忽略字段、丢弃复数或静默回退为英文。

这是**自有的受限转换器**，不是 Apple 编译器的等价替代。本轮没有找到完整 JSON 编译格式的稳定官方承诺，需固定输入子集并验证生成语义。该设计需要用户确认后才在相应里程碑实现，不引入额外第三方转换库。

UI 通过统一 `L10n` 边界取文案，显式指定资源 bundle；可从 Catalog 生成类型化键，减少散落字符串。没有 Xcode 自动提取时，目录完整性检查和中英文运行检查成为构建要求。

依据：[String Catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)、[运行期复数](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals)。

## 5. 图标与应用资源

不依赖 `.xcassets` 编译作为候选路线的前置步骤：

- 原创应用图标维护为 `.iconset`，由系统 `iconutil` 生成 `.icns`，使用 `CFBundleIconFile` 指定。
- PNG / PDF 等直接作为命名文件读取；系统符号按 macOS 14 可用性使用。
- 不在本轮制作图标或界面素材，也不引入资源生成器依赖。
- 只有进入实际 UI 里程碑后，才验证深浅色、缩放、显示效果和资源加载。

标准包布局：

```text
DockShell.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/DockShell
    ├── Frameworks/                       # 仅实际需要的已签名库
    └── Resources/
        ├── DockShell.icns
        ├── en.lproj/
        ├── zh-Hans.lproj/
        └── <实际构建产生的资源包>.bundle
```

自己的资源通过显式 `ResourceLocator` 从 `Bundle.main.resourceURL` 定位，并注入 UI / L10n。不要假设手工放到 `Contents/Resources` 后所有 `Bundle.module` 都能自动找到：生成访问器可能搜索 `.app` 根目录并回退到构建机绝对路径。需检查当前工具链实际生成文件和各依赖实现。

打包验收必须把 `.app` 移动到其他位置，并使原 `.build` 路径不可访问，再验证图片、本地化、依赖资源及启动行为。

依据：[Apple Bundle 布局](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)、[CFBundleIconFile](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)、[SwiftPM 资源访问器源码](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift)。

## 6. SwiftTerm 与 Metal

验证版本为官方 SwiftTerm **1.19.0**，SPM 地址 `https://github.com/migueldeicaza/SwiftTerm.git`。本轮临时探针实际解析 ArgumentParser **1.8.2**，地址 `https://github.com/apple/swift-argument-parser.git`，仅为上游传递依赖，不新增产品直接依赖。

该版本 macOS 终端默认使用 CoreGraphics，Metal 默认关闭。但这不避免默认构建系统先编译 `.metal` 资源：本轮默认构建真实失败。

临时探针显式使用 `--build-system native` 后成功，构建日志复制了 `Shaders.metal`。这可作为固定当前工具链的技术过渡候选；工具已经明确提示 native 将来会移除，不应将它作为无需维护的长期保证，也不静默更换构建方式。

打包应保留实际输出的 `SwiftTerm_SwiftTerm.bundle` 原名及内容。该版本自己的 Metal 资源查找明确支持 `Contents/Resources/SwiftTerm_SwiftTerm.bundle`，避免依赖生成的 `Bundle.module` 绝对路径回退。Metal 还存在从源码运行时编译的路径，但本轮没有运行它。

尚待验证：终端 UI、中文/emoji、IME、鼠标、真实 macOS 14、Metal 初始化与回退、移动安装目录，以及大量输出下的响应和内存。不能用选择 CoreGraphics 或无 Xcode 作为放宽原性能验收的理由。

如果未来 CLT 移除 native，或原版依赖在新工具链下无法构建，应报告门槛，再由用户决定完整工具链构建或批准其他方案；不能借此擅自 fork 或补丁。

依据：[Package.swift](https://github.com/migueldeicaza/SwiftTerm/blob/v1.19.0/Package.swift)、[macOS 视图](https://github.com/migueldeicaza/SwiftTerm/blob/v1.19.0/Sources/SwiftTerm/Mac/MacTerminalView.swift)、[Metal 与资源查找](https://github.com/migueldeicaza/SwiftTerm/blob/v1.19.0/Sources/SwiftTerm/Apple/Metal/MetalTerminalRenderer.swift)。

## 7. SSH 后端与 C 库的构建边界

SSH 路线仍依据 [M0 对比报告](M0/SSH底层路线对比.md) 由用户决定。

- Citadel：M0 已在本机 CLT 编译原版探针，当前锁定图要求 Swift 6.4；协议与平台缺口仍存在，不能因构建方式改变而忽略。
- libssh2：若获选，需要把 libssh2 和获批 crypto 依赖面向 macOS 14 重建。实验使用的 Homebrew OpenSSL 不能作为用户运行依赖。
- 系统 OpenSSH：无需链接三方 SSH 库，但进程、PTY、凭据 helper、主机信任和 SFTP 结构化能力的成本不变。

完全 CLT 的 C 库集成不能以 `xcodebuild -create-xcframework` 为前置条件。可另设计自有 SPM C 模块加载项目内的固定静态制品，由可复现脚本构建并记录官方源码版本、SHA 和架构；SwiftPM 管理模块依赖，脚本承担其不直接提供的 C 构建步骤。这一正式依赖集成方案和 crypto 版本仍需用户批准。

若采用外部完整 Xcode 构建机，可由该机器生成 XCFramework，再由 SPM binaryTarget 消费。两种方案都不使用个人 Swift wrapper 作为必需依赖，也不自动新增 CMake/Homebrew 等产品依赖。

## 8. 测试、调试与签名公证

- M0 的独立 CLI 断言可继续运行，已通过的 SSH 探针不受完整 Xcode 缺失影响。
- 后续业务测试优先评估工具链自带 Swift Testing；必须实际验证测试发现、宏加载与执行，不能只验证 `import Testing`。
- 不把 Swift Testing 当作 XCUITest 的替代。没有完整 Xcode 测试环境时，保留真实界面、IME、窗口缩放和睡眠唤醒的人工验收；自动化 UI 测试可交给获批准的构建机。
- 若 CLT 版本缺少所需测试框架或插件，采用明确的验证可执行程序记录断言结果，或在完整工具链机器运行测试；不擅自添加测试库。
- 本机已找到 `codesign`、`notarytool` 和 `stapler`。签名/公证本身不强制本机安装完整 Xcode；Developer ID 身份、Hardened Runtime、嵌入库签名和票据仍需在发布阶段配置与验证。
- 公证凭据使用 Keychain profile 或适当的安全认证流程，不写进脚本、参数示例或日志。本轮不签名、不提交公证，也不读取账户凭据。

依据：[Apple CLT 说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)、[公证工具的独立安装说明](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)、[Swift Testing](https://developer.apple.com/documentation/testing)。

## 9. 实施前的决策与门槛

2026-10-27 已确认：直接在当前 CLT 环境构建，系统 OpenSSH 作为 SSH 后端，系统 SQLite 替代 SwiftData，M1 已实现并验证。没有建立外部构建机或服务。

后续门槛：

1. M2 实现 SQLite 事务、迁移、凭据引用与 Keychain 协调。
2. M3 单独接入 SwiftTerm，处理本文件所列 Metal 与构建方式风险；M1 未以更换终端库规避问题。
3. M4/M5 实现系统 SSH 的 PTY、主机信任、凭据 helper、断线检测及恢复。
4. macOS 14 实机、双架构和签名公证仍需独立验收。

第三方补丁和新增依赖的批准规则不变。本轮只完成 M1，不提前实现后续里程碑。
