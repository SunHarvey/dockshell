// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockShellKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DockShellDomain", targets: ["DockShellDomain"]),
        .library(name: "DockShellApplication", targets: ["DockShellApplication"]),
        .library(name: "DockShellInfrastructure", targets: ["DockShellInfrastructure"]),
        .library(name: "DockShellTerminalUI", targets: ["DockShellTerminalUI"]),
        .library(name: "DockShellFeatures", targets: ["DockShellFeatures"]),
        .library(name: "DockShellTerminalDiagnostics", targets: ["DockShellTerminalDiagnostics"]),
        .library(name: "CDockShellPTY", targets: ["CDockShellPTY"]),
    ],
    dependencies: [
        .package(path: "../../Vendor/SwiftTerm"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CDockShellPTY", linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DockShellDomain"),
        .target(name: "DockShellApplication", dependencies: ["DockShellDomain"]),
        .target(name: "DockShellInfrastructure", dependencies: ["DockShellDomain", "CSQLite", "CDockShellPTY"]),
        .target(name: "DockShellTerminalUI", dependencies: [
            "DockShellDomain", "DockShellApplication",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .target(
            name: "DockShellFeatures",
            dependencies: ["DockShellDomain", "DockShellApplication", "DockShellTerminalUI"]
        ),
        .target(name: "DockShellTerminalDiagnostics", dependencies: [
            "DockShellDomain", "DockShellApplication", "DockShellTerminalUI", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
