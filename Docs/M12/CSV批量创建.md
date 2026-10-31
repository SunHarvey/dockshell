# M12.2：CSV 批量创建服务器

更新日期：2026-11-01。本页记录 **0.3.0 / build 24** 的开发与验收，相关功能纳入 **v0.4.0 / build 25**，见 [版本说明](../ReleaseNotes/v0.4.0.md)。已发布的 **v0.3.0 / build 22 不含 SSH 配置导入或 CSV 批量创建**。M12.1 的功能和原有会话继续保留。

## 使用

1. 退出旧版 DockShell，在仓库根目录执行 `sh Scripts/run.sh`。
2. 选择右上角 **＋ → CSV 批量创建服务器…**，或系统菜单 **会话 → CSV 批量创建服务器…**。
3. 选择已有分组，或输入新分组名。默认名称为 **csv-import**，输入已存在的同名分组时复用它。
4. 点击“选择文件…”打开 CSV，或将内容粘贴到输入框后点击“预览服务器”。“使用示例”可以填入下面的非真实服务器示例。
5. 预览中可以直接修改名称；展开“连接详情”编辑主机、端口、用户名、认证方式和私钥路径。更改私钥路径或切换为私钥认证后，点击“校验私钥”。
6. 选择需要创建的行。目标分组内同名行和本批重复行会标记“同名 · 将跳过”；修改名称、切换分组或调整勾选后即时重新计算。
7. 点击“导入会话”。只创建已勾选且有效的行，结果显示新增数量及同名跳过明细，侧栏立即更新。不会自动连接服务器。

“更换 CSV”返回输入阶段并清空旧预览，不能误保存上一次内容；粘贴原文保留以便修改。文件来源返回时可重新选择文件或粘贴新内容。预览和取消不写数据库；确认成功后清空原始 CSV 草稿，关闭窗口后不保留输入历史。

## CSV 格式

完整示例：[Examples/servers.csv](../../Examples/servers.csv)。界面中的示例使用相同格式。

```csv
name,host,port,username,auth,key_path
web-01,192.0.2.11,22,root,agent,
app-01,192.0.2.12,2222,admin,password,
db-01,192.0.2.13,22,ubuntu,key,~/.ssh/id_ed25519
```

| 列 | 规则 |
|---|---|
| `name` | 必需列；会话名称，不能为空，可在预览修改 |
| `host` | 必需列；主机名或 IP，沿用现有会话校验，不执行 DNS 查询 |
| `username` | 必需列；不能为空，可在预览修改 |
| `auth` | 必需列；`agent`、`password` 或 `key`，不区分大小写。为空或写错时要求在预览中明确选择，不静默回退 |
| `port` | 可选列；缺列或留空使用 22，范围 1–65535 |
| `key_path` | 可选列，仅 `key` 认证使用；填写外部私钥的绝对路径或当前用户 `~/` 路径。私钥认证必须提供有效路径 |

表头不区分大小写、可调整顺序；去除表头首尾空格。不得有重复列或未列出的其他列，包括密码、口令等列。本轮一个批次选择一个分组，CSV 不含分组列。

仅支持 UTF-8（允许 BOM）和英文逗号分隔，接受 LF、CRLF 或 CR。字段包含逗号时使用双引号；字段内双引号写成两个双引号：

```csv
name,host,port,username,auth,key_path
"生产,一号",192.0.2.11,22,root,agent,
"say ""hello""",192.0.2.12,22,root,agent,
```

解析器可以识别引号内换行，但会话字段仍需满足既有校验，例如名称、主机和用户名内部的换行会明确报错，不会产生隐藏的额外服务器。名称、主机、端口、用户名与认证值去除首尾空白；**私钥路径保留原值**，不移除文件名的有效空格。不要在路径字段周围添加多余空格；有逗号或双引号时按 CSV 规则引用。

不展开环境变量、其他用户 `~user` 或 SSH config 的 `%` token；相对路径不会猜测为当前工作目录，需在预览修正为绝对路径。路径只引用外部文件，不复制或改写私钥；密码和私钥口令在连接时输入，保存仍走 Keychain。

## 校验、跳过与事务

- 格式正确但字段无效的行保留在预览中，可以修改；未知认证显示“请选择认证方式”，必须明确选择后才能导入。
- 引号、表头等结构错误显示本地化提示；引号错误给出源文件行号。列数与表头不一致的行标明行号和列数并禁用选择，需修正原始 CSV 后重新预览。
- 字段错误不会阻止同批其他有效行被选择和导入。确认按钮只提交已勾选且有效的行。
- 同名比较与 M12.1 一致：仅目标分组内，名称去首尾空白后，忽略大小写及音调差异。现有会话及凭据引用从不覆盖；不同分组可以保留同名会话。
- 新分组、重名检查与本批插入复用 M12.1 的单笔 SQLite 事务。中途任何存储错误整批回滚，不能留下部分会话或空分组。
- 保存前重新预检私钥，不能凭过期的预览书签绕过校验。未知认证在业务服务层再次拒绝，不能绕过 UI 直接落库。
- 输入上限为总计 2,000,000 字节、1000 台服务器、每字段 16,384 字节和每条记录 32 列。文件只接受普通文件，FIFO 等会立即拒绝。读取、解析和私钥 IO 均在 Actor 中执行。

不引入额外依赖、数据库迁移或第三方库补丁。CSV 由独立 `SessionCSVReading` 协议接入，具体读取器只在 AppContainer 装配；UI 与业务层继续不依赖基础设施实现。

## 验证

```sh
sh Scripts/test-csv-import.sh
sh Scripts/test-csv-import.sh release
sh Scripts/test-session-import.sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh
```

测试只使用临时目录、生成的私钥、内存凭据库和隔离 SQLite；不读取个人配置、私钥、会话或 Keychain，不连接任何服务器。覆盖：

- UTF-8 BOM、中英文、emoji、引号、转义、逗号、换行、物理行号、重排表头、可选列与默认端口、200 条生成数据的解码比较。
- 空文件、重复/缺失/额外表头、密码列拒绝、错误引号、编码错误、非普通文件、取消和大小/行数边界。
- 三种认证元数据、外部私钥及 `~/`、文件名有效空格、分组复用、同组/批内重名跳过、明确修正未知认证、重启读取及零凭据写入。
- 中英文原生多行文本编辑，实际点击预览与确认按钮，现有/新分组、预览改名、勾选、无效字段修正、错误本地化、文件路径接入、清空草稿与取消不写库。

本机 Debug / Release CSV 专项、M12.1 SSH 配置导入、默认回归、完整原生 UI、资源搬迁与本地签名检查均通过；脚本、工作流 YAML、示例和完整文件链接检查通过。结果见 [开发记录](../Development-History.md)。macOS 14 实机、系统文件选择器中实际选择文件，以及用户自己的 CSV / 服务器手工验收仍待确认。以上是 M12.2 开发阶段的验收记录；后续 v0.4.0 发布不改变尚未完成的人工待验范围，也不会自动替换本机已安装应用。

## 完整文件索引

- [CSV 协议、错误与格式示例](../../Packages/DockShellKit/Sources/DockShellDomain/SessionCSV.swift)
- [共用预览数据](../../Packages/DockShellKit/Sources/DockShellDomain/SessionImport.swift)
- [CSV 读取器与有界解析](../../Packages/DockShellKit/Sources/DockShellInfrastructure/CSVSessionReader.swift)
- [共用业务校验与事务入口](../../Packages/DockShellKit/Sources/DockShellApplication/WorkspaceService.swift)
- [共用预览模型](../../Packages/DockShellKit/Sources/DockShellFeatures/SessionImportViewModel.swift)
- [输入与预览界面](../../Packages/DockShellKit/Sources/DockShellFeatures/SessionImportView.swift)
- [工作区模型](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceViewModel.swift)
- [窗口入口与导入路由](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift)
- [系统菜单](../../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceCommands.swift)
- [中英文本地化键](../../Packages/DockShellKit/Sources/DockShellFeatures/Localization.swift)
- [String Catalog](../../Localization/Localizable.xcstrings)
- [服务装配](../../DockShellApp/AppContainer.swift)
- [当前版本](../../Packaging/Info.plist)
- [CSV 示例文件](../../Examples/servers.csv)
- [专项测试](../../Tools/Verification/M122CSVVerification.swift)
- [验证程序入口](../../Tools/Verification/Verification.swift)
- [专项脚本](../../Scripts/test-csv-import.sh)
- [CI](../../.github/workflows/ci.yml) / [Release 工作流](../../.github/workflows/release.yml)
