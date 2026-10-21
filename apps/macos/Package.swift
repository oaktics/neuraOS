// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NeuraOS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NeuraOS", targets: ["NeuraOS"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [.executableTarget(name: "NeuraOS", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")])],
    swiftLanguageModes: [.v5]
)
