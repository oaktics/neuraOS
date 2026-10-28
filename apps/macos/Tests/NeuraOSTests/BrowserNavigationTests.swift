import XCTest
@testable import NeuraOS

final class BrowserNavigationTests: XCTestCase {
    @MainActor func testBrowserAddressesRejectLocalFilesAndEmbeddedCredentials() {
        XCTAssertEqual(BrowserModel.navigationURL(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserModel.navigationURL("http://localhost:3000")?.host, "localhost")
        XCTAssertEqual(BrowserModel.navigationURL("about:blank")?.absoluteString, "about:blank")
        for input in ["", "file:///etc/passwd", "javascript://alert(1)", "https://user:secret@example.com"] {
            XCTAssertNil(BrowserModel.navigationURL(input), input)
        }
    }
    @MainActor func testLinksOpenNewSelectedTabsWithWorkspaceScopedAddresses() throws {
        let suite = "BrowserLinksTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let terminal = WorkspaceTab(kind: "shell")
        var layout = WorkspaceTabState(tabs: [terminal], selectedId: terminal.id)
        let firstURL = try XCTUnwrap(URL(string: "https://github.com/org/repo/pull/1#discussion"))
        XCTAssertTrue(layout.openBrowser(firstURL, workspaceId: "workspace-a", defaults: defaults))
        let first = try XCTUnwrap(layout.tabs.last)
        XCTAssertEqual(layout.selectedId, first.id)
        XCTAssertEqual(first.kind, "browser")
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "workspace-a.\(first.id)", workspaceId: "workspace-a", defaults: defaults), firstURL.absoluteString)
        XCTAssertNil(defaults.string(forKey: "browser.workspace-b.\(first.id)"))
        XCTAssertTrue(layout.openBrowser(URL(string: "http://localhost:3000")!, workspaceId: "workspace-a", defaults: defaults))
        XCTAssertEqual(layout.tabs.last?.number, 2)
        XCTAssertNotEqual(layout.selectedId, first.id)
        XCTAssertEqual(layout.tabs.first, terminal)
        XCTAssertEqual(defaults.string(forKey: "browser.workspace-a.\(first.id)"), firstURL.absoluteString)
        let selected = layout.selectedId
        for value in ["file:///etc/passwd", "mailto:person@example.com", "javascript:alert(1)", "https://user:secret@example.com"] {
            XCTAssertFalse(layout.openBrowser(URL(string: value)!, workspaceId: "workspace-a", defaults: defaults))
        }
        XCTAssertEqual(layout.tabs.count, 3)
        XCTAssertEqual(layout.selectedId, selected)
    }

    func testBrowserTitleUsesExistingWorkspaceTabAndRestoresLegacyTabs() throws {
        let old = Data("{\"id\":\"old\",\"kind\":\"browser\",\"number\":2}".utf8)
        var tab = try JSONDecoder().decode(WorkspaceTab.self, from: old)
        XCTAssertEqual(tab.title, "Browser 2")
        tab.browserTitle = "Gmail"
        XCTAssertEqual(tab.title, "Gmail")
        let restored = try JSONDecoder().decode(WorkspaceTab.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(restored.title, "Gmail")
        XCTAssertEqual(restored.id, "old")
    }
}
