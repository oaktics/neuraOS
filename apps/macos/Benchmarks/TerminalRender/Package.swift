// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Stand-alone render benchmark. It is not part of the app package, so normal
// builds and CI do not compile it. By default it measures the vendored
// SwiftTerm; SWIFTTERM_PATH points it at any other SwiftTerm checkout (for
// example upstream v1.20.0) to compare the same workload through public API.
let comparison = ProcessInfo.processInfo.environment["SWIFTTERM_PATH"]
let package = Package(
    name: "TerminalRenderBench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SwiftTerm", path: comparison ?? "../../Vendor/SwiftTerm")],
    targets: [.executableTarget(name: "TerminalRenderBench",
                                dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
                                // Work counters exist only in the vendored copy.
                                swiftSettings: comparison == nil ? [.define("NEURA_RENDER_STATISTICS")] : [])],
    swiftLanguageModes: [.v5]
)
