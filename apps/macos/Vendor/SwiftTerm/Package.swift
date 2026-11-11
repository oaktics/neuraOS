// swift-tools-version:6.0
// Vendored SwiftTerm v1.20.0 (see VENDORED.md). Only the macOS library target
// is kept; upstream's executables, tests and build-info plugin are not.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            resources: [.process("Apple/Metal/Shaders.metal")]
        )
    ],
    swiftLanguageModes: [.v5]
)
