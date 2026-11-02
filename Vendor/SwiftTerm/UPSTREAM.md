# SwiftTerm：DockShell 本地补丁包

- 上游版本：**1.19.0**。
- 上游 SPM 地址：`https://github.com/migueldeicaza/SwiftTerm.git`。
- 固定提交：`464df5207fc2432e16c9a23abe538187196daf5f`。
- 本地构建标识：`1.19.0+dockshell.2`。
- 许可：[MIT](LICENSE)，应用分发继续附带原始版权声明。
- 授权：2026-10-30，用户明确同意制作最小补丁、验证后接入。
- 警告清理授权：2026-11-02，用户要求清理启动日志列出的 warning；仅对两个未使用的返回值作显式丢弃，不改终端或缓冲区行为。

仅收录该提交的 `Sources/SwiftTerm` 库源码与许可证；没有复制 Git 历史或示例工程。原始 manifest 保留为 [Package.swift.upstream](Package.swift.upstream)。本地 [Package.swift](Package.swift) 只声明 macOS 14 终端库与原有 Metal 资源，通过 SPM 的本地路径接入，不构建上游命令工具、文档插件或其依赖。

## 唯一行为补丁

[font-resize-preserve-modes.patch](font-resize-preserve-modes.patch) 仅修改 `AppleTerminalView.resetFont()`：字体指标更新后沿用 `processSizeChange`，即普通窗口缩放的处理路径。原先调用的公共 `resize(cols:rows:)` 会额外执行 `terminal.softReset()`，清除光标、输入、字符属性与颜色等终端状态。

公共 `resize(cols:rows:)` 的既有行为未变。字号调整仍会改变行列数、使搜索和辅助功能缓存失效、通知上层并更新滚动条；光标几何和重绘继续执行原逻辑。滚动区域与行列调整遵循上游普通窗口缩放规则，运行中的程序仍需处理正常的 SIGWINCH。

`Sources/SwiftTerm/SwiftTermBuildInfo.swift` 是本地包的固定构建元数据，替代上游从 Git 动态生成信息的插件，避免误用 DockShell 仓库的版本信息。除本页两个补丁覆盖的文件及该本地元数据外，其余上游库文件保持逐字节一致。

补丁前 `AppleTerminalView.swift` 的 SHA-256：

```text
7a3c09c59ef54bcd0263708a1f4184908860935e1febd12e55fb1b77f891d376
```

补丁后 SHA-256：

```text
58c84442c9ba5f192882056dfd69a6c4c1afcc0cfa52d205c7720bc4fce44b0f
```

## 编译警告清理（不改变行为）

[metal-buffer-unused-result.patch](metal-buffer-unused-result.patch) 在 `MetalTerminalRenderer` 的两个 `vertices.withUnsafeBytes` 调用前添加 `_ =`，显式丢弃内部 `memcpy` 返回的目标指针。复制长度、缓冲区分配、所有权、绘制与完成回调均不变，不压制其他编译器诊断。SPM 地址、上游版本与固定提交不变，没有额外 fork 或依赖。

`Apple/Metal/MetalTerminalRenderer.swift` 补丁前 SHA-256：

```text
1f36a036f8e9d11a48aa487a257c8c01ed013bc568a055ef97478adb8fc79cff
```

补丁后 SHA-256：

```text
54377d10842f09b1a014b14045945e892c2c4413025b14e7483cfd9acd34db07
```

升级上游时，先对照固定提交和补丁，在独立副本验证模式保留、字体指标、当前与后台标签、真实 PTY 的 vim / top、窗口尺寸及输入法，再更新本目录。不得仅更改版本文字或在 SwiftPM 缓存中临时打补丁。
