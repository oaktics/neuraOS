// swift-tools-version:5.9
// Vendored HighlighterSwift 3.1.0 (see VENDORED.md). Only the library target
// and the themes neuraOS uses are kept.
import PackageDescription

let package = Package(
    name: "Highlighter",
    platforms: [.macOS(.v11)],
    products: [.library(name: "Highlighter", targets: ["Highlighter"])],
    targets: [
        .target(
            name: "Highlighter",
            path: "Sources",
            exclude: ["Assets/LICENCE"],
            resources: [
                .copy("Assets/highlight.min.js"),
                .copy("Assets/styles/default-light.css"),
                .copy("Assets/styles/atom-one-dark.css"),
                .copy("Assets/styles/atom-one-light.css")
            ])
    ]
)
