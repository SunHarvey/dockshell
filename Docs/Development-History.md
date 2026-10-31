# DockShell 开发与验收记录

> 本文保留首次公开提交时的开发过程、版本调整与验收记录。当前功能和安装入口请看 [项目 README](../README.md)。以下命令均在仓库根目录运行；临时日志和本机构建产物不随仓库分发。历史设计稿已从当前分支移除，本地原文件保留，相关原稿链接指向历史提交。

原生 macOS SSH 终端客户端。Swift 6、SwiftUI / AppKit、SPM，最低系统 macOS 14。

## 2026-10-31：v0.3.0 发布准备

用户明确批准提交并发布 **v0.3.0**，发布构建号 **22**，包含 M10 终端日志和 M11 独立批量命令栏；标题沿用仅版本标签的形式。发布说明见 [v0.3.0](ReleaseNotes/v0.3.0.md)。作者与 SSH 提交签名保持 SunHarvey，历史标签不移动或覆盖，历史品牌设计、本机产物和用户数据不纳入提交。

沿用 arm64、ad-hoc 签名与现有 GitHub Actions DMG 发布流程；不引入 Apple 开发者账号或公证配置。目标平台与人工待验边界继续保留，完成情况以实际 Actions 和 Release 元数据为准。

发布前在 0.3.0 / build 22 下通过 Release 默认回归与搬迁、日志和批量命令专项、发布参数守卫；本地分发应用、嵌套签名、DMG 镜像完整性、正常 /Volumes 只读重新挂载及品牌布局审计通过。仅源码、文档与测试纳入提交，云端结果以对应 Actions 为准。

## 2026-10-31：M11 批量命令与日志角标调整

当前源码 **0.2.0 / build 21**。按用户反馈移除 SSH 与本机终端右上角的日志图标，日志默认记录、右键状态/开关/导出和错误提示继续保留。

用户确认独立批量命令栏方案：通过 **⋯ 更多操作 → 批量执行命令** 展开，单行命令加一次回车进入全部已连接 SSH 标签的原有有界输入队列，后台和分屏同样参与，同配置的多个连接分别发送。等待认证、连接中、断线的目标跳过，单目标队列满只拒绝该项；报告明确区分排队、跳过和拒绝，不声称远端执行成功。不自动连接或重试，不向重连后的连接重放旧命令，普通终端按键与协议回复继续隔离，本机 shell / SFTP 不参与。

命令和草稿不落入设置、数据库、报错或历史记录；校验 16 KiB UTF-8 上限、单行和控制字符。展开批量栏时自动聚焦规则统一由模型维护，布局层不再覆盖，因此选中连接重连完成不会抢走正在输入的草稿。关闭命令栏后恢复当前终端正常焦点。未新增依赖，未修改第三方库或补丁。

模型与中英文原生 UI 专项覆盖按钮点击、Return、中文/emoji、360/220/180pt 布局、认证跳过、队列满、重排/分屏、关闭、重连不重放、重连不抢焦点与草稿清理；两个私有 HOME 的真实 zsh PTY 各执行同一中文命令一次。Release 验证中将虚拟终端的持有周期显式延长到重连测试结束，避免优化器提前释放测试表面；没有通过放宽断言掩盖问题。

Debug / Release 批量专项、中英文原生按钮/回车、双 shell 实际执行均通过，焦点修正后的工作区与字体回归也通过；此前完成的两种配置默认回归、Debug 完整 UI、应用搬迁和日志专项均通过。YAML、脚本和文件链接检查通过，远端 Actions 未运行。

完整实现、命令和实际验收边界见 [M11 批量命令](M11/批量命令.md)。本轮只本地开发与验证，不向个人服务器发送命令，不创建标签或发布 Release，也不替换已安装的应用。

## 2026-10-31：M10.1 终端日志接入应用

当前源码为 **0.2.0 / build 20**。SSH 与本机 shell 默认自动记录，每次连接独立保留最近 5 MB（十进制字节），可在设置关闭或改为 1–100 MB，保存后立即影响当前和后台终端。终端右键提供开始 / 暂停记录和导出 UTF-8 日志，状态使用小图标和菜单，不恢复已移除的底部栏。

提取复用实际 SwiftTerm 解析器的公开回调；备用屏幕只记录进入/退出时间。连接重连创建新日志，关闭或退出先收集未换行尾部并等待后台队列。分段文件通过协议隔离，IO 在后台进行，超限删除最早分段；导出在打开系统保存面板前固定快照，权限 0600，同名或符号链接目标明确拒绝。认证框密码、私钥口令与原始按键不接入日志。未新增依赖、未修改第三方库或补丁。

Debug / Release 的 M10.1 应用集成、默认回归和应用搬迁均通过，已有字体即时设置、真实 vim / top、当前/后台标签及原生终端模式检查通过。20,000 行中文/emoji 共 1,640,014 输入字节的日志逐字节比较通过，超过滚屏历史仍完整；本机最终 Debug 为 1.564 秒、主线程心跳最大间隔约 17.5 ms，Release 为 0.392 秒、约 15.3 ms。受控慢盘队列过载与存储失败检查确认错误可见、已接收队列收尾，终端仍可输入输出。新增脚本语法、发布守卫、工作流 YAML 与完整文件链接检查通过；CI/Release 工作流增加日志集成检查，但本轮没有远端执行、创建标签或发布 Release。

自动化成功导出采用可替换的目的地选择协议和真实文件存储；系统 NSSavePanel 的实际显示、命名、本地化和取消已有验证，面板内实际鼠标点击保存、个人 Linux 服务器手工日志验收与 macOS 14 实机仍待用户确认。未替换已安装应用，不访问个人会话或凭据。使用、验证命令、所有完整文件与边界见 [M10.1 终端日志接入与验收](M10/终端日志接入与验收.md)。

## 2026-10-31：M10.0 终端日志技术验证

用户确认默认开启日志、可在设置中关闭，每连接分别保留最近 5 MB、超限滚动删除，并可调整容量；备用屏幕只记录进入/退出时间，终端内右键提供导出位置选择。原先建议的“默认关闭、50 MiB 分卷保留”不再适用。

新增独立 `M10/TerminalLogging` 命令行探针与 `Scripts/test-terminal-logging.sh`，验证当前 SwiftTerm 的既有公开回调、跨块 UTF-8、宽字符、退格/CR、软折行、滚动历史、清屏、尺寸变化、备用屏幕及记录关闭边界；不新增第三方依赖或补丁。文件原型以小段 UTF-8 文本滚动淘汰，通过 Actor 与有界后台 worker 提供每连接容量调整、稳定快照、0600 独占导出及连接停止后导出。

Debug / Release 均通过合成输出、12,322,890 字节写入及滚动、独立连接预算、容量缩小/扩大、同名/符号链接拒绝、临时文件清理和真实隔离 PTY 的 vim / 一次性 macOS top 验证。本轮不构建 DockShell.app、不访问用户会话或服务器，不改变已安装应用、版本或 Release。实际 UI、默认开启设置和右键导出仍属 M10.1，不能当作本轮已经可用。详细结果与限制见 [终端日志技术验证](M10/终端日志技术验证.md)。

## 2026-10-30：v0.2.0 发布准备

用户批准以 **v0.2.0 / build 19** 发布包含 SFTP 目录浏览、文件上传下载与队列的版本。Release 标题统一为版本标签本身；版本正文使用 [v0.2.0 说明](ReleaseNotes/v0.2.0.md)，保留直接下载的 DMG、校验文件与清单。签名沿用现有 ad-hoc 模式，未完成 Apple 公证与 macOS 14 实机验收。

发布前核对发现旧 CI 在侧栏模拟点击上失败。字体专项改用无需鼠标派发的原生终端视图检查，继续验证当前 / 后台标签、尺寸、模式与真实隔离 PTY 的 vim / top；侧栏交互检查保留在完整 GUI 验证入口。验证窗口先解除焦点、显式卸载宿主视图，再关闭窗口，保留视图与控制器释放断言。修正后的专项、Release 默认回归与应用搬迁、本机真实 DMG 构建和只读重新挂载审计均通过。工作流发布后会核对标题与标签完全一致，并匿名下载 DMG 验证校验和。

## 2026-10-30：移除工具栏共享玻璃外框

按界面反馈，在 macOS 26 及以上隐藏四个操作按钮的系统共享玻璃背景，较旧系统保留原有无边框样式。按钮组由 36pt 压紧为 28pt，图标 15pt、左右各 8pt 留白及各自的悬浮 / 选中反馈保留。编译通过，并在只使用临时会话库与模拟通道的独立原生预览中目视确认外框消失、按钮与标题同排；没有操作用户已有连接，也未发布 Release。

## 2026-10-30：设置保存后即时生效

经用户明确批准，对固定 SwiftTerm 1.19.0 制作最小字体缩放补丁，验证模式保留后接入本地 SPM 包；来源、原 manifest、许可证、diff 和版本摘要保存在 `Vendor/SwiftTerm`。只修改上游 `resetFont()` 的缩放路径，普通视图 resize API 保持原行为；本地库封装不再解析上游命令工具或文档插件依赖。

移除 SSH 与本机 Shell 的字体冻结：保存后字体、字号、主题与历史上限即时更新当前、后台和分屏终端，不重连、不重启 Shell。字体变化同步 PTY 行列；适配器避免在仅更换字体时重新安装主题，以保留服务器颜色。设置窗口补充中英文即时生效说明。紧凑标题栏保留，右侧工具栏容器单独恢复为 36pt、常规控件尺寸。

专项已验证终端模式、输入法组合与提交、宽字符、主机颜色、当前 / 后台 SSH 视图身份及尺寸回调；真实隔离本机 PTY 中运行 vim / top，在换字体后继续中文编辑、核对 vim 实际行列并退出回到 shell。Debug 原生回归、Debug / Release 默认回归与资源搬迁、Release 字体专项及真实回环 SSH/SFTP 集成均通过；来源核对确认 84 个上游库文件仅一处行为文件有差异，构建 / 发布脚本守卫与工作流 YAML 检查通过。macOS 14 实机与个人 Linux 会话的手工字体操作不计为已验。CI / Release 工作流加入同一专项。本轮不发布 Release。详细范围与验证入口见 [终端设置即时生效](终端设置即时生效.md)。

## 2026-10-30：精简工作区工具栏

右上角由八个入口收敛为四个图标：新建 / 打开连接、远程文件、终端布局和更多操作。新建菜单收纳新建会话、连接选中会话及本机终端；更多菜单收纳当前连接信息、取消 / 断开 / 重连 / 关闭与设置。独立连接状态胶囊移除，各标签的状态圆点与错误提示保留。

分组管理移至左侧分组标题右侧，原有全宽选择器继续用于范围筛选。图标统一为 28pt 操作区，提供悬浮底色、选中状态及中英文用途提示；⌘N / ⌘T 由系统菜单承载，避免依赖工具栏弹出菜单的生命周期。设置仍支持 ⌘,。

Debug / Release 编译、现有默认回归、原生标签 / 分屏 / 文件面板检查及应用资源搬迁通过；实际窗口的四图标布局、分组管理菜单、更多菜单打开设置与用途说明已核对。系统“会话”菜单显式安装快捷键，已实际验证启动后直接按 ⌘N 打开编辑表单，未选中会话时连接菜单项禁用。没有新增依赖、改动版本或发布 Release。

## 2026-10-30：同名传输策略调整

按反馈将同名上传改为直接原子覆盖；下载保留原文件并自动添加 ` (1)`、` (2)` 等编号，不再创建临时文件后等待同名选择。最终提交发生名称碰撞时保留已下载数据并重试下一个编号，已同步完成路径显示与中英文文件选择说明。本轮仍不发布 Release。

## 2026-10-30：M9.2 SFTP 文件上传与下载

新增普通文件多选上传、下载和每标签串行队列，显示进度、取消与同名文件决定。传输使用独立 SSH 连接，取消不会直接退役目录浏览或终端；未保存的认证输入可能再次请求。文件夹递归、断点续传和退出后的任务恢复不在本轮范围。

文件先写入同目录独占临时文件，核对传输结果后才提交到最终名称；已有目标需要明确确认，远端没有 `posix-rename@openssh.com` v1 时只提供跳过或另存为。上传请求 `0600`，服务端可按 umask 或策略进一步收紧，最终提交沿用临时文件权限，不保留原远端权限和额外元数据；本机新下载文件以 `0600` 创建，替换本机普通文件时沿用原 POSIX 权限。取消先协作清理，对端无响应时关闭自己的传输连接；提交结果未确认和清理残留会显示路径并保留记录。正常标签关闭包含确认、等待收尾及警示保留流程。

Debug / Release 最终构建、默认回归、应用搬迁、传输引擎、本机文件和队列专项均通过；Debug 的既有及新增 GUI 回归通过。两种构建的中英文字段、可滚动表单和布局检查通过，冲突、密码及结果未确认界面截图已目视检查；离屏宿主的按钮辅助功能动作不可可靠读取，实际鼠标点击与本机文件选择仍待人工验收。两种构建的真实隔离 sshd 传输均完成 1 MiB 上传 / 下载、内容核对及确认后的原子替换。个人服务器手工传输与 macOS 14 实机尚未验收，远端 CI 结果另记。按用户要求不修改版本、不打标签、不发布 Release，无新增第三方依赖。实际边界与测试结果见 [M9.2 SFTP 文件传输](M9/SFTP文件传输.md)。

## 2026-10-30：M9.1 SFTP 目录浏览界面

新增终端右侧可收起、可调整宽度的 SFTP 目录面板。每个标签首次打开时才建立独立文件连接，保留自己的目录、搜索与隐藏项状态；隐藏面板保留连接，关闭标签清理连接及认证决定。支持目录双击、路径输入、上级 / 主目录 / 刷新、目录优先自然排序及文件大小、修改时间；普通文件只展示，上传下载留给 M9.2。

文件面板复用主机信任与 Keychain 服务，拥有独立的密码和口令提示。原始路径字节保留，控制与双向文字字符安全转义；中文和含 ZWJ 的组合 emoji 正常显示。权限或路径错误保留上次成功的列表，连接失败可手动重连。闲置断线在下一次文件操作时呈现，未宣称新增即时状态事件。

Debug / Release 默认回归、应用搬迁、文件浏览模型与中英文 UI 专项均已通过；文件面板覆盖 380pt 两列和 520pt 三列布局，展开 / 隐藏 / 调整宽度时的终端身份与尺寸同步检查及既有 UI 回归保持通过。合成界面截图已目视检查，真实隔离 sshd 的目录浏览模型在两种构建中也通过。本轮提交的远端 CI 结果另行记录；本轮没有执行真实虚拟机的手工文件面板或密码 UI 验收，macOS 14 实机仍待提供。

按用户本轮要求不发 Release：应用版本与公开 v0.1.2 保持，未打新标签。使用当前源码启动和手工验证步骤见 [M9.1 SFTP 目录浏览](M9/SFTP目录浏览.md)。本轮无新增第三方依赖。

## 2026-10-30：M9.0 SFTP 底层技术验证

已落实系统 OpenSSH 独立连接、无 PTY 二进制管道和自有 SFTP v3 协议层，未新增第三方依赖、fork 或文件面板 UI。终端与文件连接共享主机信任和认证规则，各自持有进程及一次性凭据 broker；SSH READY 后仍需完成 SFTP INIT/VERSION 握手。

Debug 与 Release 默认回归及应用搬迁均通过；本地隔离 sshd 的 Debug、Release 集成也通过，覆盖 OpenSSH/PEM、加密口令、独立 agent、协议往返和取消隔离。用户授权 Linux 虚拟机的真实私钥、密码认证均完成 1 MiB 精确字节与 SHA-256 往返、特殊文件名及测试目录清理。真实密码验收使用测试控制器的隔离输入及匿名 FIFO，密码不进入参数、环境变量、普通文件或日志；人工前台 TTY 输入分支调整后尚未交互复验。

发布脚本守卫、新脚本语法与两个工作流 YAML 解析通过，CI / Release 已配置显式回环 SFTP 集成步骤；远端 Actions 执行结果另记。macOS 14 实机仍未提供验收环境。公开 Release 保持 v0.1.2，本轮没有发布新版安装包。文件面板与用户传输任务留给 M9.1 / M9.2。技术边界和验证命令见 [M9.0 SFTP 技术验证](M9/SFTP技术验证.md)。

## 原 M8 阶段历史记录

当前提供 **M8：可排序标签与横排 / 竖排 SSH 工作区** 的本机预览，在当前 `DeckShell` 目录开发；产品和模块统一命名为 DockShell。一个标签对应一条独立连接，全部已打开终端可横排成一行、或竖排成一列，按所选方向平均分配空间，不新建标签或连接。标签最左侧显示从 1 开始的当前编号，名称居中，可左右拖动调整顺序；排序、切换和关闭单项均保留其他连接及终端内容。远程终端底部的提示 / 尺寸栏与工作区底部状态栏已移除，将高度交给终端。会话管理、SQLite / Keychain、三种认证、主机指纹确认、基础设置、心跳和睡眠恢复策略继续适用。尚未实现 SFTP、端口转发等其余第二阶段功能。

最新标签行为与验证见 [标签排序与终端空间说明](../Docs/M8/标签排序与终端空间.md)，横排 / 竖排的精确规则见 [横排与竖排说明](../Docs/M8/横排与竖排.md)；自动网格和早期双面板结果保留为历史记录。真实分屏 IME 与 M6 的目标环境待验项继续保留：最终包真实 IME、真实 VM 密码保存后重启登录、实际睡眠、macOS 14 实机与正式签名 / 公证，不能因布局检查通过而视为完成。

**0.1.0 / build 9** 首次接入 **61「浅浮雕壳」**作为无字标图标。此稿保留为历史设计，当前图标见 build 13；侧栏、空白工作区与应用的 Dock / Finder 图标始终共用同一份批准的资源。

**0.1.0 / build 10** 将侧栏默认宽度和拖动范围调整为此前的 3/4：默认约 199pt，范围约 173–255pt；标题与副标题保持单行，副标题可悬停查看完整内容。

本轮已编译并通过现有多标签、原生侧栏选择、界面布局与资源搬迁检查；1080pt 验证窗口中的侧栏实测为 199pt。验证使用独立的 `Build/Sidebar-Verification` 应用副本，记录位于 `/private/tmp/dockshell-build10-sidebar.log`。

**0.1.0 / build 11** 删除侧栏名称下的副标题，并将原来的离线样例入口改为真正的“本机终端”：启动当前账号配置的默认交互式登录 shell，以账号主目录为初始目录，可执行 `ls`、`top` 等本机命令。旧样例输出仅保留在开发诊断中。

**0.1.0 / build 12** 将侧栏分组入口改为全宽原生选择栏：左侧图标、单行组名、右侧展开箭头；弹出菜单至少与入口等宽，长组名在入口截断并可悬停查看全文。侧栏仍约 199pt，选择栏实测为 171pt、两侧各留 14pt，保留原有分组过滤和键盘选择行为。

本轮通过现有多标签、侧栏原生点击、界面布局与应用搬迁检查，最终记录位于 `/private/tmp/dockshell-build12-groups-final.log`；宽度测量位于 `/private/tmp/dockshell-build12-groups.log`。完整实现见 [SidebarGroupSelector.swift](../Packages/DockShellKit/Sources/DockShellFeatures/SidebarGroupSelector.swift)、[WorkspaceView.swift](../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift) 和 [Info.plist](../Packaging/Info.plist)。

**0.1.0 / build 13** 将图标换成 **49「紧凑厚折」**：象牙白折纸与深海蓝背景；同时精修全宽分组栏的背景、图标底座、文字、展开箭头与交互状态。原有分组筛选、原生键盘选择和菜单宽度规则继续适用。

分组入口采用 34pt 高的圆角轻卡片、淡色图标底座和单展开箭头，增加悬停、按下和键盘焦点状态，适配浅色 / 深色外观；长名称保持单行截断，并可悬停查看全文。原生菜单至少与入口等宽，仍由 AppKit 处理选择、键盘与辅助功能。

本轮编译、现有多标签与原生界面检查、191 个双语资源键、10 个图标表示及应用搬迁检查通过；浅色与深色外观已查看截图。验证使用 `Build/Branding-Group-Verification` 独立副本，记录位于 `/private/tmp/dockshell-build13-final.log`；没有启动或退出用户正在使用的应用。最终代码中不保留截图与测量的临时夹具。

本轮修改的完整文件：

- [SidebarGroupSelector.swift](../Packages/DockShellKit/Sources/DockShellFeatures/SidebarGroupSelector.swift)：分组入口绘制、状态与原生菜单桥接。
- [DockShellBrand.swift](../Packages/DockShellKit/Sources/DockShellFeatures/DockShellBrand.swift)、[WorkspaceView.swift](../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift)：批准图标的资源约定注释。
- [generate-icons.sh](../Scripts/generate-icons.sh)、[49 号生产图](../Packaging/Branding/Source/DockShell-49.png)、[处理提示词](../Packaging/Branding/Source/DockShell-49.prompt.txt)、[DockShell.icns](../Packaging/Branding/DockShell.icns)、[DockShellMark.png](../Packaging/Branding/DockShellMark.png)：49 号来源和导出资源。
- [Verification.swift](../Tools/Verification/Verification.swift)：图标验证输出不再绑定历史设计编号。
- [Info.plist](../Packaging/Info.plist)：build 13 版本声明。

**0.1.0 / build 14** 将标签名称从 12pt 调整为 13pt，常规标签宽度从 184pt 缩至 152pt，缩短约 17%。名称仍按整个标签居中，编号位于左侧，关闭按钮保留独立热区；分屏内的标签沿用相同样式，空间不足时继续缩小并截断长名称。文字高度改由 AppKit 测量，避免字号变化导致中文或字母下伸部被裁切。

本轮编译、现有多标签、拖动排序、独立关闭、溢出滚动、窄分屏标签与资源搬迁检查通过，并查看了中英文标签截图。记录位于 `/private/tmp/dockshell-build14-tabs.log` 与 `/private/tmp/dockshell-build14-final-build.log`；使用独立的 `Build/Compact-Tabs-Verification` 应用副本，临时截图夹具已移除。修改的完整源文件为 [TerminalTabBar.swift](../Packages/DockShellKit/Sources/DockShellTerminalUI/TerminalTabBar.swift) 和 [Info.plist](../Packaging/Info.plist)，未新增依赖。

**0.1.0 / build 15** 将标签上下留白从各 6pt 缩为各 2pt，标签栏总高从 44pt 降为 36pt。普通标签与分屏面板共用同一高度，标签仍为 32pt 高、152pt 宽、名称 13pt；拖动插入线同步对齐标签，节省的高度交给终端。

完整实现见 [TerminalTabBar.swift](../Packages/DockShellKit/Sources/DockShellTerminalUI/TerminalTabBar.swift)、[TerminalTabsPane.swift](../Packages/DockShellKit/Sources/DockShellFeatures/TerminalTabsPane.swift) 和 [Info.plist](../Packaging/Info.plist)。现有 [M7TabBarVerification.swift](../Tools/Verification/M7TabBarVerification.swift) 与 [M8SplitUIVerification.swift](../Tools/Verification/M8SplitUIVerification.swift) 同步使用共享栏高，未新增依赖。

编译、标签拖动 / 关闭 / 溢出滚动、窄标签、应用搬迁，以及横排 / 竖排往返、各面板尺寸、输入焦点和认证表单检查通过。记录位于 `/private/tmp/dockshell-build15-tabs.log` 与 `/private/tmp/dockshell-build15-splits.log`；使用 `Build/Compact-Strip-Verification` 独立副本和合成连接，未操作用户的实际连接。

**0.1.0 / build 16** 将标签名称从 13pt 放大到 15pt，编号从 11pt 放大到 12pt；标签本身从 32pt 压缩到 28pt，减少文字上下的内部留白。外部上下各 2pt，总栏高同步降为 32pt，普通 / 分屏共用；宽度仍为 152pt，关闭按钮保留 26×26pt 操作区。名称与编号均按实际字体高度垂直居中。

完整修改文件为 [TerminalTabBar.swift](../Packages/DockShellKit/Sources/DockShellTerminalUI/TerminalTabBar.swift) 和 [Info.plist](../Packaging/Info.plist)。编译、现有标签拖动 / 关闭 / 溢出、窄标签、资源搬迁与分屏尺寸 / 焦点 / 认证检查通过，并查看了英文、中文、emoji 和字母下伸部的预览。验证使用 `Build/Compact-Text-Verification` 独立副本，日志为 `/private/tmp/dockshell-build16-tabs.log`、`/private/tmp/dockshell-build16-final-build.log` 和 `/private/tmp/dockshell-build16-splits.log`；临时预览代码已移除，未新增依赖。

2026-10-27 已确认的选择：

- 使用现有 Command Line Tools，不安装完整 Xcode，不登录 Apple Account。
- SSH 后端采用系统 `/usr/bin/ssh`，由自有协议、PTY 与已签名辅助程序适配。
- 会话持久化采用系统 SQLite，替代原方案的 SwiftData；密码与私钥口令仍保存到 Keychain。
- SwiftTerm 已固定原版 1.19.0；不 fork、不修改第三方源码。

## 构建和运行

先用 ⌘Q 退出已打开的 DockShell，再在本目录的终端中执行：

```sh
sh Scripts/run.sh zh-Hans
```

脚本检查工具链，编译 SwiftPM 模块，将 String Catalog 转为运行时资源，组装并进行本地临时签名，然后打开应用。首次构建会通过 SPM 下载锁定的 SwiftTerm 及其解析依赖；无需安装完整 Xcode 或登录 Apple Account。

启动后新建或选择会话，选择密码、外部私钥或本机 ssh-agent 认证，点击“在新标签中连接”。首次连接须核对 SHA-256 主机指纹；确认后才读取 Keychain、询问本次密码或口令、检查私钥或探测 agent。保存密码需在编辑会话时选择“将密码保存到钥匙串”；连接页面临时输入的密码或私钥口令不会自动保存。私钥内容保留在外部文件；PuTTY PPK 需要先转换为 OpenSSH。主机公钥发生变化时停止连接，不自动覆盖记录。

双击侧栏会话、使用右键菜单，或选中会话后点击工具栏“在新标签中连接” / 按 ⌘T，可以打开另一个独立标签。点击标签切换；标签上的 × 只关闭该条连接，关闭窗口会结束窗口内所有标签。

标签编号单独放在最左侧，会话名称按标签全宽居中，关闭按钮在右侧。按住标签名称区域左右拖动，在插入标记处松开即可重排；编号随当前顺序从 1 连续更新，分屏面板也按新顺序排列。拖动不会切换当前选中连接或重新认证；取消拖动保持原顺序。工作区内各分屏标签之间也可拖动。

打开至少两个连接后，点击工具栏的“终端布局”菜单，选择“横排（左右并列）”或“竖排（上下堆叠）”，也可选择“标签视图”返回普通切换。横排永远是一行 N 列，所有终端等宽、全高；竖排永远是一列 N 行，所有终端等高、全宽。三个连接就是三列或三行，不自动组合成二维网格。原连接标签在普通模式显示于顶部、分屏模式显示于各自面板，不复制标签。点击面板或标签选择输入目标，× 只关闭该连接，其余按当前方向重新均分；只剩一条时自动恢复标签视图。布局切换不弹出会话选择器、不重新认证；主动新开的连接会加入当前布局。右上角连接状态菜单继续提供当前连接的取消、断开、重连和关闭。build 4 移除的大型信息栏和居中标题不恢复。

“打开本机终端”启动当前用户的默认 shell，不需要建立 SSH 会话。初始目录来自账号主目录；可用 `pwd`、`ls`、`top` 验证，在 `top` 中按 `q` 返回、Ctrl-C 中断前台命令。输入 `exit` 或 Ctrl-D 结束 shell 后，可点击“重新打开”；关闭本机终端会回收它的 shell 与普通前台任务。此轮沿用单一本机入口，只在所有远程标签关闭后可用。通过齿轮按钮或 ⌘, 打开字体、字号、三主题及历史设置。默认历史 10000 行，可设 1000–100000 行。SSH 连接或本机 shell 运行期间，字体和字号延后到下次连接 / 重新打开后生效，配色与历史上限即时生效。

SSH 每 15 秒发送协议心跳，连续 3 次无响应时由系统 SSH 结束连接并显示原因。点击“重新连接”重新建链；不会自动重复认证。Mac 睡眠期间保留已连接会话，唤醒后不将旧连接直接判死。正在建立的认证过程会在睡眠时取消。

英文与系统默认语言：

```sh
sh Scripts/run.sh en
sh Scripts/run.sh
```

运行脚本会检查旧进程，避免重新构建后仍显示旧界面。已运行时请先用 ⌘Q 退出，再重新启动。语言参数只影响本次进程，不修改系统语言。

也可以只构建，然后双击生成的应用：

```sh
sh Scripts/build.sh
open Build/debug/DockShell.app
```

请运行打包后的 `.app`。直接 `swift run DockShell` 不负责组装资源包。

## 验证

```sh
sh Scripts/test.sh
```

自动检查包含双语资源、M2/M3 回归、主机信任与损坏文件保护、签名辅助程序的凭据隔离、真实 PTY 的 cooked / IUTF8 初始化与 SIGWINCH、4 MiB 双向字节与背压、连接取消、输入限额、生命周期、本地签名及资源搬迁，以及 OpenSSH / PEM 容器、隔离 agent、口令桥接、睡眠事件和重连回收。M6 新增 SQLite 路径安全和新进程验证入口的范围拒绝检查。M7 覆盖同会话多开、输入 / 认证隔离、后台输出、关闭和释放。最新 M8 检查覆盖七个既有连接的横排 / 竖排 / 标签模式往返、定向均分几何、三个实际终端的固定父视图与历史保留、逐项关闭重排、各自 PTY 尺寸及焦点 / 协议回复隔离。默认使用随机临时数据，不连接服务器，不读取个人私钥或已有 Keychain 项。辅助程序测试只使用合成密码。独立性能、真实 SSH 渲染与 Keychain 重启集成需显式开启，入口和实测见 M6 文档。

build 11 还验证本机终端的挂载、取消、字体策略、退出码与重启关闭顺序，以及真实 PTY 下的目录、中文 `ls`、stderr、SIGWINCH、交互式 `top`、Ctrl-C 和前台进程回收。真实 shell 测试固定使用 `/bin/zsh -f -i`，HOME / ZDOTDIR / cwd 均位于随机临时目录，跳过个人 shell 配置。仅运行这一组：

```sh
DOCKSHELL_APP_OUTPUT_ROOT="$PWD/Build/Local-Terminal-Verification" DOCKSHELL_LOCAL_TERMINAL_TEST=1 sh Scripts/test.sh
```

build 8 新增标签左侧编号、整标签名称居中、原生鼠标排序、阈值与取消、边缘滚动任务清理、分屏全局顺序和终端正文填满底部的检查。独立可见窗口的双向真实鼠标拖动与自动事件链分别记录，证据见 [本轮验证记录](../Docs/M8/标签排序与终端空间.md#本轮验证记录)。

build 9 的资源验证增加应用图标声明、10 个标准 / Retina 图标表示、16–1024 像素解码，以及 256px 界面图片的显式资源加载；搬迁检查也会核对这些资源。可使用独立输出目录验证，保留当前开发应用：

```sh
DOCKSHELL_APP_OUTPUT_ROOT="$PWD/Build/Branding-Verification" DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh
```

实际 Keychain 读写验证只使用随机测试 service，并在结束后删除测试项：

```sh
DOCKSHELL_KEYCHAIN_TEST=1 sh Scripts/test.sh
```

在具有图形桌面的会话中，还可检查实际终端的 UTF-8、颜色、主题、滚屏、尺寸、IME 提交、鼠标及关闭释放，以及多标签 / 横排 / 竖排原生宿主的画面保留、协议回复、焦点、定向均分和各面板 PTY 尺寸同步：

```sh
DOCKSHELL_UI_SMOKE=1 sh Scripts/test.sh
```

本项目在 Codex 的受限工具环境中构建时，若嵌套 SPM sandbox 不可用，可仅对这一条命令使用：

```sh
DOCKSHELL_DISABLE_SPM_SANDBOX=1 sh Scripts/test.sh
```

普通终端默认保留 SPM sandbox。SwiftTerm 的已审计 BuildInfo 插件在自己的构建目录生成版本信息；它不访问网络或凭据。此开关不解除外层工具权限。

当前 CLT 缺少 Metal 离线编译工具，脚本显式使用已验证的 `--build-system native`。它已弃用，将来可能移除；工具链升级需重新验证。没有修改上游资源或 manifest 来绕过限制。

Release 本机构建：

```sh
sh Scripts/build.sh release
```

输出在 `Build/release/DockShell.app`。带 Hardened Runtime 的 Apple Silicon 本地预览包另行生成：

```sh
sh Scripts/release.sh --local-preview
```

应用、ZIP 和校验文件放在 `Build/distribution/` 下的新目录。此包只供本机预览，采用 ad-hoc 签名，尚未获得 Developer ID 签名或公证。本轮没有签名证书和 macOS 14 测试环境，没有上传或公开发布。复查、正式签名和将来的公证入口见 [M6 分发准备](../Docs/M6/分发准备.md)。

## 模块

| 模块 | 当前职责 |
|---|---|
| `DockShellDomain` | 非敏感会话、主机公钥、信任与凭据交互边界、SSH 连接、本机 shell 工厂与公共终端字节协议 |
| `DockShellApplication` | 会话业务、有界字节通道、IO pump、本机样例/回显与设置业务 |
| `DockShellInfrastructure` | SQLite、Keychain、书签、设置、OpenSSH 传输、主机信任、凭据桥接、本机 shell 工厂与 PTY 通道 |
| `DockShellTerminalUI` | SwiftTerm 桥接、原生输入、本机 / SSH 控制器、字体应用策略与关闭清理；保留离线诊断控制器 |
| `DockShellFeatures` | 会话、远程 / 本机终端、信任与密码提示、设置、MainActor ViewModel 与本地化 |
| `DockShellApp` | 入口、异步启动和具体依赖组装 |
| `CDockShellPTY` / `DockShellSSHHelper` | 自有 POSIX 桥接与固定 SSH/askpass 辅助程序；不实现密码学算法 |

`DockShellNetworkTestSupport` 仅链接验证器，提供可选网络黑洞夹具，不进入应用，也没有新增产品转发功能。

本机终端与 SSH 共用有界 PTY 与 `TerminalByteChannel`，但使用独立的工厂和控制器；本机 UI 不依赖 `Process`、C 或具体网络库。默认 shell / 主目录从系统账号取得，切换目录和环境只发生在新启动的辅助进程中。标准错误并入本机 PTY，使提示符与命令错误正常显示；SSH 的独立诊断通道保留。关闭本机终端时处理所属 PTY 会话的前台进程组，随后回收 shell；主动脱离终端会话的守护进程不在此清理范围内。

UI 和业务模块不导入 SQLite、SwiftData 或具体 SSH 库。会话配置存于系统 Application Support 下的 `DockShell/sessions.sqlite`；Keychain service 为 `dev.dockshell.credentials`。密码、口令不写入数据库或日志。删除分组保留其会话；凭据清理失败会显示警告并可重试。

## 本机终端实现与验证

build 11 已通过 Debug 完整回归、SwiftUI / AppKit 界面检查、临时 HOME 中的真实 shell 测试及资源搬迁。记录：`/private/tmp/dockshell-build11-debug-full.log`；单独本机测试记录：`/private/tmp/dockshell-build11-local.log`。最后核对还修正了共享终端的辅助功能标签，使本机与 SSH 视图均使用准确的通用说明。打开入口会等待保存设置加载完成，避免首次启动时提前冻结默认字体。

Apple Silicon Release 本地预览位于 DockShell 0.1.0 / build 11（本机构建路径：`Build/distribution/DockShell-0.1.0-11-arm64-local-preview-20261029T041745Z/DockShell.app`）。签名、空 entitlements、macOS 14 部署目标、资源篡改拒绝、ZIP 校验与含空格路径的解压审计均通过；没有执行个人登录配置。ZIP 的 SHA-256：`e529819c3757db1c8f36d71b619cf31b858474e10b32494a4056de2ca7439d30`。原有 M6 真实环境验收及正式签名 / 公证待验项保持在原记录中。

以下均链接到完整文件；本轮没有新增第三方依赖。

| 文件 | 职责 |
|---|---|
| [Ports.swift](../Packages/DockShellKit/Sources/DockShellDomain/Ports.swift) | 公共终端字节 IO；SSH 通道继承公共边界 |
| [LocalTerminal.swift](../Packages/DockShellKit/Sources/DockShellDomain/LocalTerminal.swift) | 本机工厂、通道、退出状态与错误协议 |
| [TerminalIOPump.swift](../Packages/DockShellKit/Sources/DockShellApplication/TerminalIOPump.swift) | 本机与 SSH 共用 4KiB 有界输出泵 |
| [SystemLocalTerminalFactory.swift](../Packages/DockShellKit/Sources/DockShellInfrastructure/SystemLocalTerminalFactory.swift) | 本机 PTY 工厂及子进程环境 |
| [PTYProcessChannel.swift](../Packages/DockShellKit/Sources/DockShellInfrastructure/PTYProcessChannel.swift) | 本机启动与隔离验证入口 |
| [CDockShellPTY.h](../Packages/DockShellKit/Sources/CDockShellPTY/include/CDockShellPTY.h) | 本机 PTY 启动的 C 边界 |
| [pty_runtime.c](../Packages/DockShellKit/Sources/CDockShellPTY/pty_runtime.c) | 本机前台进程组关闭与 shell 回收 |
| [main.c](../Tools/SSHHelper/main.c) | 系统账号、默认登录 shell、主目录、控制终端与 stderr |
| [LocalTerminalController.swift](../Packages/DockShellKit/Sources/DockShellTerminalUI/LocalTerminalController.swift) | 启动 / 退出 / 重启状态与有界 IO 生命周期 |
| [LocalTerminalPane.swift](../Packages/DockShellKit/Sources/DockShellFeatures/LocalTerminalPane.swift) | 真正的本机终端界面，替换样例面板 |
| [WorkspaceView.swift](../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift) | 删除副标题与本机入口接入 |
| [TerminalSettingsView.swift](../Packages/DockShellKit/Sources/DockShellFeatures/TerminalSettingsView.swift) | 已加载状态与打开时机 |
| [Localization.swift](../Packages/DockShellKit/Sources/DockShellFeatures/Localization.swift) / [Localizable.xcstrings](../Localization/Localizable.xcstrings) | 191 个类型化双语键 |
| [AppContainer.swift](../DockShellApp/AppContainer.swift) | 注入本机后端 |
| [LocalTerminalVerification.swift](../Tools/Verification/LocalTerminalVerification.swift) | 真实临时 PTY、命令、交互与前台清理 |
| [LocalTerminalControllerVerification.swift](../Tools/Verification/LocalTerminalControllerVerification.swift) | 挂载、队列、EOF、重启、过期输出与释放 |
| [VerificationLocalTerminalFactory.swift](../Tools/Verification/VerificationLocalTerminalFactory.swift) | 界面夹具不执行用户 shell |
| [Verification.swift](../Tools/Verification/Verification.swift) | 本机专项与完整回归入口 |
| [M7WorkspaceUIVerification.swift](../Tools/Verification/M7WorkspaceUIVerification.swift) / [M8SplitUIVerification.swift](../Tools/Verification/M8SplitUIVerification.swift) | 适配本机控制器的隔离界面夹具 |
| [Info.plist](../Packaging/Info.plist) | build 11 版本声明 |

## 本地化

唯一人工维护的文案源是 [Localizable.xcstrings](../Localization/Localizable.xcstrings)。`Tools/CatalogCompiler` 使用系统 Foundation 生成独立的 `DockShellResources.bundle`；应用按自身资源目录定位，不使用构建机器的绝对路径。

首版只接受 `en` / `zh-Hans` 的普通完整译文。复数、格式占位符和其他 variation 尚未实现，遇到这些输入会让构建失败。不要手工修改 `Build/Generated`。

## 依赖

M8 的直接第三方库仍为原版 SwiftTerm，解析版本提交于根 `Package.resolved`：

| 依赖 | 版本策略 | 地址 / 集成 |
|---|---|---|
| OpenSSH | 使用目标 macOS 自带版本 | `/usr/bin/ssh` 与 `/usr/bin/ssh-keyscan`；无需 SPM 下载，M4 已接入 |
| SQLite | 使用目标 macOS 自带版本 | 自有 SPM `CSQLite` systemLibrary，链接系统 `sqlite3` |
| SwiftTerm | **1.19.0** | `https://github.com/migueldeicaza/SwiftTerm.git` |
| ArgumentParser（上游解析依赖） | **1.8.2**；不链接进应用 | `https://github.com/apple/swift-argument-parser` |

M0 候选探针的依赖与应用工程相互独立；没有将 Citadel、libssh2 或 Homebrew OpenSSL 引入正式应用。SwiftTerm 许可随应用资源打包。原版字体更改会软重置部分终端模式；M4 已按用户确认的策略冻结连接期间的字体与字号，详见 M4 文档。

## 品牌资源

当前使用的 **49 号**圆角资源由内置图像工具依据[选定原稿](https://github.com/SunHarvey/dockshell/blob/fb804e1c13bdfae0fe026f6a7881508d493016dd/Design/Branding/Shell-Refinements-41-50/49-compact-fold.png)准备，未添加字标。[生产资源](../Packaging/Branding/Source/DockShell-49.png)和[完整处理提示词](../Packaging/Branding/Source/DockShell-49.prompt.txt)均保留，先前的 61 号资源也保留在 Source 中。重新导出应用尺寸：

```sh
sh Scripts/generate-icons.sh
```

导出器只缩放并封装原图，使用 CLT 自带的 Foundation / CoreGraphics / ImageIO，无新增依赖。当前 CLT 的 `iconutil` 拒绝标准 iconset，ImageIO 的直接 ICNS 写入也会遗漏部分尺寸，因此导出器使用系统 PNG 编码和标准 ICNS 元素，随后通过系统解码器逐项检查全部尺寸。正常构建直接使用已导出的资源。

界面 PNG 在原有后台启动任务中读取并解码一次，视图复用不可变图片。路径从应用内显式资源 bundle 获取，应用搬迁后仍可读取；缺失或损坏时走现有启动错误提示。品牌变更未调整会话、凭据、连接、分屏或终端主题。

build 9 的历史检查：Debug 完整回归、SwiftUI / AppKit 界面检查、资源搬迁、10 个图标表示解码均通过；Release 的 arm64 本地预览构建、嵌套签名、Hardened Runtime、资源篡改拒绝、ZIP 校验及含空格路径解压审计通过。验证使用 `Build/Branding-Verification` 副本，未启动或退出用户的实际应用。记录位于 `/private/tmp/dockshell-build9-debug-full.log`、`/private/tmp/dockshell-build9-preview.log` 和 `/private/tmp/dockshell-build9-artifact-guards.log`。当前 build 13 的验证结果见本文开头。

build 9 历史预览位于 DockShell 0.1.0 / build 9（本机构建路径：`Build/distribution/DockShell-0.1.0-9-arm64-local-preview-20261029T033931Z/DockShell.app`），其中使用旧的 61 号图标。其 ZIP 的 SHA-256 为 `7ce3ef3ecbf3191b35dcc9f0164df46b5e5d48a854ade335dae23ab4eab50c09`。正式 Developer ID / 公证及既有 M6 环境待验项继续按原记录保留。

build 9 品牌接入的完整文件：

| 文件 | 职责 |
|---|---|
| [DockShellBrand.swift](../Packages/DockShellKit/Sources/DockShellFeatures/DockShellBrand.swift) | 品牌图片资源读取与后台解码 |
| [Localization.swift](../Packages/DockShellKit/Sources/DockShellFeatures/Localization.swift) | 随显式资源上下文加载品牌图片 |
| [WorkspaceView.swift](../Packages/DockShellKit/Sources/DockShellFeatures/WorkspaceView.swift) | 侧栏与空白页显示新标志 |
| [IconExporter.swift](../Tools/IconExporter/IconExporter.swift) | 标准 / Retina PNG 表示、ICNS 封装与解码验证 |
| [generate-icons.sh](../Scripts/generate-icons.sh) | 从批准的资源导出图标文件 |
| [install-branding.sh](../Scripts/install-branding.sh) | 在签名前安装图标和界面图片 |
| [package-app.sh](../Scripts/package-app.sh) | 开发应用品牌打包与独立输出目录 |
| [release.sh](../Scripts/release.sh) | 发布预览品牌资源打包 |
| [audit-release.sh](../Scripts/audit-release.sh) | 图标声明与资源检查 |
| [test.sh](../Scripts/test.sh) | 独立应用副本与搬迁验证 |
| [Verification.swift](../Tools/Verification/Verification.swift) | 标准 / Retina 与显式资源验证 |
| [Info.plist](../Packaging/Info.plist) | 应用图标声明、build 9 |
| [DockShell.icns](../Packaging/Branding/DockShell.icns) / [DockShellMark.png](../Packaging/Branding/DockShellMark.png) | 应用图标与 256px 界面图片 |

## 文档与完整文件

- [M8 横排与竖排、已有连接均分和完整文件索引](../Docs/M8/横排与竖排.md)
- [build 8 标签编号、拖动排序与终端空间](../Docs/M8/标签排序与终端空间.md)
- [build 6 自动网格历史记录](../Docs/M8/自动网格.md)
- [M8 基础分屏、会话选择、验收和完整文件索引](../Docs/M8/基础分屏.md)
- [M7 多标签历史验证与文件索引](../Docs/M7/多标签开发方案.md)
- [M6 验收矩阵、持久化安全和 Keychain 重启验证](../Docs/M6/验收矩阵.md)
- [M6 性能测量与交付记录](../Docs/M6/性能与交付记录.md)
- [M6 本地预览、签名与公证准备](../Docs/M6/分发准备.md)
- [M5 私钥、agent、心跳与唤醒、验证和完整文件索引](../Docs/M5/私钥Agent与连接恢复.md)
- [M4 历史验证记录](../Docs/M4/密码SSH与主机信任.md)
- [M3 历史验证记录](../Docs/M3/离线终端与设置.md)
- [M2 历史验证记录](../Docs/M2/会话与凭据管理.md)
- [M1 历史验证记录](../Docs/M1/工程基座.md)
- [当前开发方案](../DockShell-开发方案.md)
- [不安装 Xcode 的构建方案与历史验证](../Docs/不安装Xcode的构建方案.md)
- [M0 技术验证](../M0/README.md)
- [M0 路线对比与历史推荐](../Docs/M0/SSH底层路线对比.md)
