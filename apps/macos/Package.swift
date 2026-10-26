// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NeuraOS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NeuraOS", targets: ["NeuraOS"]),
               .executable(name: "NeuraSleepHelper", targets: ["NeuraSleepHelper"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0")
    ],
    targets: [.target(name: "SleepControl"),
              .executableTarget(name: "NeuraSleepHelper", dependencies: ["SleepControl"]),
              .executableTarget(name: "NeuraOS", dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark")
    ], resources: [.process("Resources")]),
              .testTarget(name: "NeuraOSTests", dependencies: ["NeuraOS", "SleepControl"])],
    swiftLanguageModes: [.v5]
)
