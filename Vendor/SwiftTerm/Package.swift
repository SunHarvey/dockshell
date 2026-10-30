// swift-tools-version: 6.0
import PackageDescription

// Library-only SPM wrapper for the fixed upstream source documented in UPSTREAM.md.
// No upstream command tools, documentation plugins or extra dependencies are needed.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["iOS", "Mac/README.md", "Documentation.docc"],
            resources: [.process("Apple/Metal/Shaders.metal")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
