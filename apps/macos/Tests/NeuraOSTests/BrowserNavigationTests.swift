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
