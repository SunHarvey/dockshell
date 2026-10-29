// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockShellCitadelProbe",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "citadel-probe", targets: ["CitadelProbe"])],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "CitadelProbe",
            dependencies: [.product(name: "Citadel", package: "Citadel")]
        )
    ],
    swiftLanguageModes: [.v6]
)
