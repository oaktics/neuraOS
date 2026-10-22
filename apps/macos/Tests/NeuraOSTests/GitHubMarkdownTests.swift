import AppKit
import SwiftUI
import XCTest
@testable import NeuraOS

final class GitHubMarkdownTests: XCTestCase {
    private let sample = """
    ## レビュー内容

    **Markdown表示**を確認しました。`GitHubPane.swift` の変更は [PRで確認](https://github.com/oaktics/neuraOS/pull/3) できます。

    - 見出しと箇条書きを読みやすく
      - ネストした項目も表示
    - [x] コメント・レビュー
    - [ ] ~~古い表示~~の置き換え

    > 引用したコメントです。日本語の長い文章もサイドバーの幅に合わせて折り返します。

    1. アプリを開く
    2. GitHubを選択

    ```swift
    let message = "**ここはMarkdownとして解釈しない**"
    print(message) // 長いコードは横スクロール
    ```

    | 項目 | 結果 | 補足 |
    | --- | --- | --- |
    | コメント | OK | 長い表も横スクロールで確認できます |
    | レビュー | 確認中 | リンク・引用・コードに対応 |
    """

    @MainActor func testRichContentFitsSidebarInBothAppearances() throws {
        for width: CGFloat in [220, 380] {
            for scheme: ColorScheme in [.light, .dark] {
                let view = GitHubMarkdown(source: sample, baseURL: URL(string: "https://github.com/oaktics/neuraOS/pull/3"))
                    .padding(10).frame(width: width)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                // ImageRenderer omits native scroll views and buttons; use an offscreen
                // AppKit host so the snapshot includes code blocks and tables as well.
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 1000),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1, "Wide code or tables must not expand the sidebar")
                XCTAssertGreaterThan(host.fittingSize.height, 300, "Content must retain its full vertical layout")
                XCTAssertLessThan(host.fittingSize.height, 1800, "Horizontal scrolling must not create unbounded height")
                if let directory = ProcessInfo.processInfo.environment["NEURA_MARKDOWN_SNAPSHOTS"] {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown-\(Int(width))-\(scheme).png"))
                }
            }
        }
    }
}
