// swift-tools-version: 6.0
import PackageDescription
import Foundation
let cefSDK = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".cef/sdk").path
let package = Package(
    name: "NeuraOS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NeuraOS", targets: ["NeuraOS"]),
               .executable(name: "NeuraSleepService", targets: ["NeuraSleepService"])],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", exact: "2.4.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0")
    ],
    targets: [.target(name: "SleepControl"),
              .executableTarget(name: "NeuraSleepService", dependencies: ["SleepControl"]),
              .target(name: "ChromiumBridge", publicHeadersPath: "include",
                      cxxSettings: [.unsafeFlags(["-I", cefSDK, "-fobjc-arc"])],
                      linkerSettings: [.linkedFramework("AppKit")]),
              .executableTarget(name: "NeuraOS", dependencies: [
        "ChromiumBridge", "SleepControl",
        .product(name: "Highlighter", package: "HighlighterSwift"),
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark")
    ], resources: [.process("Resources")]),
              .testTarget(name: "NeuraOSTests", dependencies: ["NeuraOS", "SleepControl"])],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
