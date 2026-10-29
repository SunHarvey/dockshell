// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockShell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DockShell", targets: ["DockShellApp"]),
        .executable(name: "catalog-compiler", targets: ["CatalogCompiler"]),
        .executable(name: "dockshell-verify", targets: ["DockShellVerification"]),
        .executable(name: "dockshell-ssh-helper", targets: ["DockShellSSHHelper"]),
    ],
    dependencies: [.package(path: "Packages/DockShellKit")],
    targets: [
        .executableTarget(
            name: "DockShellApp",
            dependencies: [
                .product(name: "DockShellTerminalUI", package: "DockShellKit"),
                .product(name: "DockShellFeatures", package: "DockShellKit"),
                .product(name: "DockShellApplication", package: "DockShellKit"),
                .product(name: "DockShellInfrastructure", package: "DockShellKit"),
            ],
            path: "DockShellApp"
        ),
        .executableTarget(name: "CatalogCompiler", path: "Tools/CatalogCompiler"),
        .target(name: "DockShellNetworkTestSupport", path: "Tools/NetworkTestSupport"),
        .executableTarget(
            name: "DockShellSSHHelper",
            dependencies: [.product(name: "CDockShellPTY", package: "DockShellKit")],
            path: "Tools/SSHHelper"
        ),
        .executableTarget(
            name: "DockShellVerification",
            dependencies: [
                "DockShellNetworkTestSupport",
                .product(name: "DockShellTerminalDiagnostics", package: "DockShellKit"),
                .product(name: "DockShellTerminalUI", package: "DockShellKit"),
                .product(name: "DockShellDomain", package: "DockShellKit"),
                .product(name: "DockShellApplication", package: "DockShellKit"),
                .product(name: "DockShellInfrastructure", package: "DockShellKit"),
                .product(name: "DockShellFeatures", package: "DockShellKit"),
                .product(name: "CDockShellPTY", package: "DockShellKit"),
            ],
            path: "Tools/Verification"
        ),
    ],
    swiftLanguageModes: [.v6]
)
