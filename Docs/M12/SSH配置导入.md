# M12.1：SSH 配置导入

更新日期：2026-11-01。本页对应 **0.3.0 / build 23** 的开发验收，相关功能纳入 **v0.4.0 / build 25**，见 [版本说明](../ReleaseNotes/v0.4.0.md)。已发布的 **v0.3.0 / build 22 不包含导入功能**。

**v0.4.1 起，界面、菜单及导入提示统一使用“服务器”名称；已有配置和凭据继续兼容。**

用户已确认批量创建采用 CSV、目标分组同名服务器默认跳过。按小步迭代约定，本轮先完成 SSH config 导入和共用预览、校验、事务保存；**CSV 解析与入口现已在 [M12.2](CSV批量创建.md) 实现**。

## 使用

1. 退出正在运行的旧版 DockShell，在仓库根目录运行 `sh Scripts/run.sh`。
2. 点击右上角 **＋ → 导入 SSH 配置…**，或系统菜单 **服务器 → 导入 SSH 配置…**。
3. 默认读取当前用户 `~/.ssh/config`；也可选择其他配置文件。文件读取和私钥预检在后台完成。
4. 默认分组名为 **local-ssh-config**。可以修改名称或选择已有分组；输入已有分组名称时复用该分组，不改名。
5. 在预览中核对服务器名、主机、端口、用户名和认证方式。展开“连接详情”可以编辑；有多把私钥时必须明确选择一把，修改路径后点击“校验私钥”。路径输入使用绝对路径。
6. 勾选需要导入的有效服务器，然后点击“导入服务器”。有错误的行不导入，目标分组内同名行跳过，结果显示实际新增数量及跳过明细。
7. 需要保留同名配置时，在确认前修改预览中的名称。导入完成不会自动连接服务器。

预览、选择和取消都不会改写原配置或服务器数据库；私钥仅引用外部文件，不复制、不导入口令。密码和私钥口令在首次连接时输入，保存仍使用原有 Keychain 流程。

## 支持与边界

| 配置 | 本轮行为 |
|---|---|
| `Host server`、一行多个别名、重复声明 | 每个具体别名一个候选；重复别名合并，标量选项取首次匹配值 |
| `Host *`、`?`、`!` 排除模式 | 只为已枚举具体别名提供继承规则，不凭空展开服务器 |
| `HostName`、`Port`、`User` | 缺省分别为别名、22、当前本机用户名；预览可改 |
| 双引号、空格、注释、等号、大小写 | 关键字不区分大小写、Host 别名区分大小写；保留引号内空格与 `#`，支持 CRLF |
| `Include` | 递归和文件名通配，按字典顺序；相对路径基于当前用户 `~/.ssh`，条件包含恢复父文件的 Host 状态 |
| Include 中缺失的匹配文件 | 和 OpenSSH 一样不产生配置；读不到已存在文件则明确报错 |
| `IdentityFile` | 多个配置累计去重；多把不自动选第一把。OpenSSH / 现有 PEM 容器按既有预检校验；PPK、缺失、格式或权限错误明确显示 |
| 私钥路径 | 支持绝对路径、`~/`，以及 `%d`、`%u`、`%h`、`%n`、`%r`、`%p`、`%%`。相对路径不猜测进程目录 |
| `HostName` token | 支持 `%h`、`%n`、`%%`；其他动态值不猜测 |
| 认证方式 | 有私钥路径时预选私钥；明确仅密码或关闭公钥时可预选密码，其余预选 agent。预览要求核对，可手动更改；不宣称复制 OpenSSH 的自动回退顺序 |
| `Match`（含 exec/final/canonical） | 本轮不求值。只要配置树含 Match，所有候选明确阻止自动导入，需选择仅有 Host 规则的配置文件 |
| `ProxyJump`、`ProxyCommand`、转发、自定义算法等未支持行为 | 匹配候选显示不支持的选项并禁止导入，不静默改成直连；显式 `none` / `no` 的禁用值仅在列明的选项中接受 |
| 心跳、主机信任、环境、ControlMaster 等应用控制的选项 | 不复制，逐行列出被省略的选项；连接仍使用 DockShell 自身策略 |
| 系统 `/etc/ssh/ssh_config` | 不隐式合并。用户可选择其他配置文件，但相对 Include 仍按用户配置规则解释 |
| 动态 Include、环境变量、其他用户的 `~user` | 不执行、不猜测，显示路径错误 |

导入是一次**快照**，后续修改原文件不会自动同步。连接继续使用 `-F none`，不绕过应用自有 known_hosts、认证或转发策略。

解析器限制累计 2 MB、128 次文件加载、16 层包含、20,000 行、每行 8,192 字节、Host 模式 1,024 字节、1,000 个具体主机，并限制目录遍历和求值复杂度；超限、循环引用、非普通文件、无效 UTF-8 均显式失败。生产导入器不调用 `ssh -G`、shell、DNS 或网络。

OpenSSH 语义依据：[ssh_config 官方手册](https://man.openbsd.org/ssh_config)、[Include 实现中的父级状态恢复](https://github.com/openssh/openssh-portable/blob/master/readconf.c)。仅支持上表列明的子集。

## 保存与重名规则

- 新分组、分组复用检查、重名检查、所有新增服务器在一笔 SQLite `BEGIN IMMEDIATE` 事务中完成。中途任何写入失败全部回滚，不能留下半批服务器或空分组。
- “同名”按目标分组内名称去除首尾空格、大小写及音调差异后比较，与既有分组名称规范化一致。预览内重复也会跳过；不同分组可保留同名服务器。
- 现有服务器及密码引用从不覆盖；普通 SQL INSERT 的 ID 冲突也会回滚。
- 确认前重新校验外部私钥；预览中的文件引用不能绕过最终检查。数据库只有书签和认证类型，本轮不写 Keychain。
- UI 只通过 Domain / Application 协议交互；具体静态读取器在 AppContainer 注入。未增加依赖、迁移或第三方库补丁。

## 验证

```sh
sh Scripts/test-server-import.sh
sh Scripts/test-server-import.sh release
sh Scripts/test.sh
```

专项使用临时 HOME、配置、生成的 Ed25519 私钥、内存凭据库和隔离 SQLite，不读取个人配置、个人私钥或个人服务器，不连接服务器。验证包括：

- 别名、继承、通配/排除、重复声明、引用与注释、Include 顺序和条件包含；对我们编写且不含命令的固定配置，比较系统 OpenSSH 输出中的主机/端口/用户。
- Match exec 零执行、路由和算法诊断、循环、动态路径、大小上限、取消、多私钥不静默选择。
- 私钥预检、同名跳过、分组复用、改名导入、半批失败回滚、重启读取和零凭据写入。
- 中英文原生窗口、Unicode 分组编辑、实际确认按钮、选择/改名后的预览、左侧数据更新，以及取消不写库。

本机 CLT 下 Debug / Release 导入专项、完整原生 UI 回归、默认回归与资源搬迁、工作流 YAML、发布脚本守卫及完整文件链接检查通过；Debug / Release 应用的本地签名检查通过。本轮未执行远端 Actions。macOS 14 实机、个人配置手工导入与真实服务器登录仍待用户验收。原生文件选择器的实际文件选择另需手工验证。

## 完整文件索引

以下均为仓库内完整文件，本轮无省略代码：

- [导入 DTO 与协议](../../Packages/DockShellKit/Sources/DockShellDomain/ServerImport.swift)
- [私钥预检端口](../../Packages/DockShellKit/Sources/DockShellDomain/Ports.swift)
- [工作区事务服务](../../Packages/DockShellKit/Sources/DockShellApplication/WorkspaceService.swift)
- [静态 SSH config 读取器](../../Packages/DockShellKit/Sources/DockShellInfrastructure/OpenSSHConfigurationReader.swift)
- [SQLite 原子导入](../../Packages/DockShellKit/Sources/DockShellInfrastructure/SQLiteServerRepository.swift)
- [外部私钥书签与预检](../../Packages/DockShellKit/Sources/DockShellInfrastructure/PrivateKeyBookmarks.swift)
- [预览模型](../../Packages/DockShellKit/Sources/DockShellFeatures/ServerImportViewModel.swift)
- [导入界面](../../Packages/DockShellKit/Sources/DockShellFeatures/ServerImportView.swift)
- [工作区模型](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceViewModel.swift)
- [窗口入口](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift)
- [系统菜单入口](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceCommands.swift)
- [本地化键](../../Packages/DockShellKit/Sources/DockShellFeatures/Localization.swift)
- [中英文 String Catalog](../../Localization/Localizable.xcstrings)
- [服务装配](../../DockShellApp/AppContainer.swift)
- [应用版本](../../Packaging/Info.plist)
- [测试实现](../../Tools/Verification/M12ServerImportVerification.swift)
- [验证入口](../../Tools/Verification/Verification.swift)
- [专项脚本](../../Scripts/test-server-import.sh)
- [CI 工作流](../../.github/workflows/ci.yml)
- [Release 工作流](../../.github/workflows/release.yml)
