import AppKit
import SwiftUI
import XCTest
import WebKit
@testable import NeuraOS

final class GitHubPresentationTests: XCTestCase {
    func testCheckAndReviewStatesRemainDistinct() {
        XCTAssertTrue(GitHubPresentation.failed("FAILURE"))
        XCTAssertTrue(GitHubPresentation.failed("TIMED_OUT"))
        XCTAssertFalse(GitHubPresentation.failed("IN_PROGRESS"))
        XCTAssertEqual(GitHubPresentation.checkLabel("IN_PROGRESS"), "実行中")
        XCTAssertEqual(GitHubPresentation.checkLabel("QUEUED"), "待機中")
        XCTAssertEqual(GitHubPresentation.checkLabel("SOMETHING_NEW"), "状態不明")
        XCTAssertEqual(GitHubPresentation.reviewLabel("CHANGES_REQUESTED"), "修正依頼")
        XCTAssertEqual(GitHubPresentation.mergeLabel("DIRTY"), "競合あり")
    }

    private func fixtureData() -> Data {
        let json = #"""
        {"repository":"oaktics/neuraOS","branch":"neura/improve-github-sidebar","head":"abcdef0123456789","defaultBranch":"main","mergeMethods":["squash","merge"],"fetchedAt":"2026-10-23T00:47:18Z","pullRequest":{
        "number":42,"title":"GitHub の Markdown 表示とレビュー体験を改善","body":"## 変更内容\n\nMarkdown とレビューの表示を改善します。\n\n- HTML コメントを非表示\n- 折りたたみに対応\n- CI の状態を表示",
        "url":"https://github.com/oaktics/neuraOS/pull/42","state":"OPEN","isDraft":false,"headRefName":"neura/improve-github-sidebar","headRefOid":"abcdef0123456789","baseRefName":"main","mergeStateStatus":"UNSTABLE","reviewDecision":"CHANGES_REQUESTED","author":{"login":"kiichi"},"additions":142,"deletions":38,"changedFiles":2,
        "files":[{"path":"apps/macos/Sources/NeuraOS/GitHubMarkdown.swift","additions":120,"deletions":30},{"path":"apps/daemon/src/github.ts","additions":22,"deletions":8}],"unresolvedThreads":1,
        "checks":[{"id":"1","name":"macOS build & tests","state":"SUCCESS","url":"https://github.com"},{"id":"2","name":"Code review","state":"IN_PROGRESS","url":null},{"id":"3","name":"Typecheck","state":"FAILURE","url":null}],
        "comments":[{"id":"comment-1","kind":"comment","body":"## Codex Review Summary\n\n**レビュー中**です。\n\n<details><summary>詳細</summary>\n\nレビューの説明です。\n\n</details>","author":"chatgpt-codex-connector[bot]","url":"https://github.com","createdAt":"2026-10-23T00:47:18Z","path":null,"line":null,"outdated":false,"state":null}]}}
        """#
        return Data(json.utf8)
    }

    func testSourcePRDoesNotHideLocalPRCreation() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var pr = try XCTUnwrap(object["pullRequest"] as? [String: Any])
        pr["state"] = "OPEN"; object["pullRequest"] = pr
        func decode() throws -> GitHubSnapshot {
            try JSONDecoder().decode(GitHubSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertFalse(try decode().canCreatePullRequest)
        object["sourcePullRequest"] = ["repository": "oaktics/neuraOS", "number": 1]
        XCTAssertTrue(try decode().canCreatePullRequest)
        object.removeValue(forKey: "sourcePullRequest")
        pr["state"] = "MERGED"; object["pullRequest"] = pr
        XCTAssertTrue(try decode().canCreatePullRequest)
        object.removeValue(forKey: "pullRequest")
        XCTAssertTrue(try decode().canCreatePullRequest)
    }

    func testOlderDaemonWithoutFileMetadataStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var pr = try XCTUnwrap(object["pullRequest"] as? [String: Any])
        for field in ["author", "additions", "deletions", "changedFiles", "files"] {pr.removeValue(forKey: field)}
        object["pullRequest"] = pr
        let old = try JSONDecoder().decode(GitHubSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.pullRequest?.files)
        XCTAssertFalse(try XCTUnwrap(old.pullRequest).canMerge)
    }

    @MainActor func testLargeConversationBoundsWebViewCount() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var prObject = try XCTUnwrap(object["pullRequest"] as? [String: Any])
        let original = try XCTUnwrap((prObject["comments"] as? [[String: Any]])?.first)
        prObject["comments"] = (0..<200).map { index in
            var comment = original
            comment["id"] = "comment-\(index)"
            return comment
        }
        object["pullRequest"] = prObject
        let snapshot = try JSONDecoder().decode(GitHubSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let pr = try XCTUnwrap(snapshot.pullRequest)
        let view = GitHubPullRequestView(pr: pr, snapshot: snapshot, disabled: false, method: .constant("squash"), merge: {}, tab: "conversation").frame(width: 380)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer {window.contentView = nil}
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        func webViewCount(_ view: NSView) -> Int {
            (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) {$0 + webViewCount($1)}
        }
        XCTAssertEqual(webViewCount(host), 20, "A conversation must only instantiate the current page's renderers")
    }

    @MainActor func testRichTabsRenderAtSidebarWidths() async throws {
        let snapshot = try JSONDecoder().decode(GitHubSnapshot.self, from: fixtureData()), pr = try XCTUnwrap(snapshot.pullRequest)
        for width: CGFloat in [260, 380] {
            for dark in [false, true] {
                for tab in ["overview", "conversation", "checks", "files"] {
                    let view = GitHubPullRequestView(pr: pr, snapshot: snapshot, disabled: false, method: .constant("squash"), merge: {}, tab: tab)
                        .font(.system(size: 12)).padding(12).frame(width: width)
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
                    try await Task.sleep(for: .milliseconds(300))
                    window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                    XCTAssertGreaterThan(host.fittingSize.height, 200)
                    if let directory = ProcessInfo.processInfo.environment["NEURA_MARKDOWN_SNAPSHOTS"] {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("github-\(tab)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                    window.contentView = nil
                }
            }
        }
    }
}
