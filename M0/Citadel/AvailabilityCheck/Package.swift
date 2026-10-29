// swift-tools-version: 6.0
import PackageDescription

// This is a separate, deliberately failing diagnostic package. The main Probe package builds normally.
let package = Package(
    name: "CitadelMacOS14AvailabilityCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "MacOS14AvailabilityFailure",
            dependencies: [.product(name: "Citadel", package: "Citadel")]
        )
    ],
    swiftLanguageModes: [.v6]
)
