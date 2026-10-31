// swift-tools-version: 6.0
import PackageDescription

// M10.0 is an isolated command-line experiment, never linked into DockShell.app.
let package = Package(
    name: "TerminalLoggingProbe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "dockshell-log-probe", targets: ["TerminalLoggingProbe"])],
    dependencies: [.package(path: "../../Vendor/SwiftTerm")],
    targets: [
        .executableTarget(
            name: "TerminalLoggingProbe",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
