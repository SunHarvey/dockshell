// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockShellLibSSH2Probe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "libssh2-probe", targets: ["LibSSH2Probe"])],
    targets: [
        .systemLibrary(name: "CLibSSH2"),
        .executableTarget(name: "LibSSH2Probe", dependencies: ["CLibSSH2"])
    ],
    swiftLanguageModes: [.v6]
)
