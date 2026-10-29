// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SystemSSHProbe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "system-ssh-probe", targets: ["SystemSSHProbe"])],
    targets: [
        .target(name: "PTYShim", publicHeadersPath: "include"),
        .executableTarget(name: "SystemSSHProbe", dependencies: ["PTYShim"])
    ],
    swiftLanguageModes: [.v6]
)
