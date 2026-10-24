import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import NeuraOS

final class GitHubMarkdownTests: XCTestCase {
    private final class ScrollEvent: NSEvent {
        weak var targetWindow: NSWindow?
        var point = NSPoint(x: 50, y: 50)
        var x: CGFloat = 0
        var y: CGFloat = -10
        override var window: NSWindow? {targetWindow}
        override var locationInWindow: NSPoint {point}
        override var scrollingDeltaX: CGFloat {x}
        override var scrollingDeltaY: CGFloat {y}
    }

    private final class RecordingScrollView: NSScrollView {
        var received: [NSEvent] = []
        override func scrollWheel(with event: NSEvent) {received.append(event)}
    }

    @MainActor func testVerticalScrollOverMarkdownReachesNativeList() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = RecordingScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let web = GitHubMarkdownScrollingWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        document.addSubview(web)
        scroll.documentView = document
        window.contentView = scroll
        defer {window.contentView = nil}
        let event = ScrollEvent()
        event.targetWindow = window
        XCTAssertTrue(web.forwardVerticalScroll(event))
        XCTAssertTrue(scroll.received.first === event)

        event.x = 20
        XCTAssertFalse(web.forwardVerticalScroll(event), "Horizontal code/table scrolling stays in WebKit")
        event.x = 0
        event.point = NSPoint(x: 250, y: 250)
        XCTAssertFalse(web.forwardVerticalScroll(event), "Other views keep their events")
        event.point = NSPoint(x: 50, y: 50)
        event.targetWindow = nil
        XCTAssertFalse(web.forwardVerticalScroll(event), "Other windows keep their events")
        XCTAssertEqual(scroll.received.count, 1)
        web.removeFromSuperview()
        XCTAssertFalse(web.forwardVerticalScroll(event))
    }

    private let sample = """
    <!-- codex-pull-request-review-summary -->
    <!-- codex-review-state:v1 {"code_review":{"status":"running","commit_sha":"4de43b6"}} -->

    ## Codex Review Summary

    This comment shows the latest **Codex review** activity on this pull request.

    | Review | Status |
    | --- | --- |
    | 📝 Code Review | 🔄 Running since <relative-time datetime="2026-10-23T00:47:18Z"></relative-time> |

    <details><summary>ℹ️ About Codex in GitHub</summary>
    <br/>

    Your team has set up Codex to review pull requests in this repo.

    - Open a pull request for review
    - Mark a draft as ready
    - [x] Completed task

    [PR link](https://github.com/oaktics/neuraOS/pull/3)

    </details>

    ```html
    <!-- visible code -->
    <details>literal example</details>
    ```
    """

    @MainActor private func javascript(_ view: WKWebView, _ code: String) async throws -> Any? {
        try await view.callAsyncJavaScript(code, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    @MainActor private func waitForContent(_ view: WKWebView) async throws {
        for _ in 0..<200 {
            if let count = try? await javascript(view, "return document.querySelectorAll('#markdown h2').length"), (count as? Int ?? 0) > 0 {return}
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Markdown did not finish loading")
    }

    @MainActor private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView {return web}
        return view.subviews.lazy.compactMap {self.webView(in: $0)}.first
    }

    @MainActor private func host(_ source: String, width: CGFloat = 380, dark: Bool = false) async throws -> (NSWindow, NSHostingView<some View>, WKWebView) {
        let content = GitHubMarkdown(source: source, baseURL: URL(string: "https://github.com/oaktics/neuraOS/pull/3"))
            .padding(10).frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(webView(in: host))
        try await waitForContent(web)
        try await Task.sleep(for: .milliseconds(100))
        window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        return (window, host, web)
    }

    @MainActor func testCodexHTMLAndDisclosureFitBothAppearances() async throws {
        for width: CGFloat in [220, 380] {
            for dark in [false, true] {
                let (window, host, web) = try await host(sample, width: width, dark: dark)
                defer {window.contentView = nil}
                let text = try await javascript(web, "return document.getElementById('markdown').textContent") as? String ?? ""
                XCTAssertFalse(text.contains("codex-review-state"))
                XCTAssertFalse(text.contains("codex-pull-request-review-summary"))
                XCTAssertFalse(text.contains("<relative-time"))
                XCTAssertTrue(text.contains("2026"))
                XCTAssertTrue(text.contains("<!-- visible code -->"), "Code examples must remain literal")
                let value1 = try await javascript(web, "return document.querySelectorAll('details').length") as? Int
                XCTAssertEqual(value1, 1)
                let value2 = try await javascript(web, "return document.querySelectorAll('table').length") as? Int
                XCTAssertEqual(value2, 1)
                let value3 = try await javascript(web, "return document.documentElement.dataset.theme") as? String
                XCTAssertEqual(value3, dark ? "dark" : "light")
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                let collapsed = host.fittingSize.height
                _ = try await javascript(web, "document.querySelector('summary').click()")
                try await Task.sleep(for: .milliseconds(150))
                window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.height, collapsed + 30, "Opening details must resize the native view")
                XCTAssertLessThan(host.fittingSize.height, 1800)
                let overflow = try await javascript(web, "return document.documentElement.scrollWidth > document.documentElement.clientWidth") as? Bool
                XCTAssertEqual(overflow, false)
                if let directory = ProcessInfo.processInfo.environment["NEURA_MARKDOWN_SNAPSHOTS"] {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("markdown-\(Int(width))-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @MainActor func testUntrustedMarkupIsRemovedAndRelativeLinksResolved() async throws {
        let malicious = """
        ## Security fixture

        <details open onclick="alert(1)"><summary>Safe summary</summary>

        <script>window.pwned = true</script>
        <iframe src="https://evil.example"></iframe>
        <svg onload="window.pwned = true"><text>unsafe</text></svg>
        <a href="javascript:alert(1)" onmouseover="alert(1)">Bad</a>
        <a href="file:///etc/passwd">File</a>
        <a href="/oaktics/neuraOS/issues/1" style="position:fixed">Issue</a>
        <img src="x" onerror="window.pwned = true">

        </details>
        """
        let (window, _, web) = try await host(malicious)
        defer {window.contentView = nil}
        let value4 = try await javascript(web, "return document.querySelectorAll('script,iframe,svg,[onclick],[onerror],[onmouseover],[style]').length") as? Int
        XCTAssertEqual(value4, 0)
        let value5 = try await javascript(web, "return document.querySelectorAll('a[href]').length") as? Int
        XCTAssertEqual(value5, 1)
        let value6 = try await javascript(web, "return document.querySelector('a[href]').href") as? String
        XCTAssertEqual(value6, "https://github.com/oaktics/neuraOS/issues/1")
        let value7 = try await javascript(web, "return document.querySelector('details').open") as? Bool
        XCTAssertEqual(value7, true)
        let value8 = try await javascript(web, "return typeof window.pwned") as? String
        XCTAssertEqual(value8, "undefined")
    }
}
