import XCTest
@testable import NeuraOS

final class DefaultBrowserTests: XCTestCase {
    func testOnlyOrdinaryWebLinksAreAccepted() {
        for url in ["https://example.com/a?b=1", "http://localhost:3000/", "HTTPS://Example.com"] {
            XCTAssertTrue(ExternalLinks.accepts(URL(string: url)!), url)
        }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "chrome://settings/", "https://user:pass@example.com", "mailto:a@example.com", "custom://example", "https:///path"] {
            XCTAssertFalse(ExternalLinks.accepts(URL(string: url)!), url)
        }
    }

    @MainActor func testLinksQueueUntilTaken() {
        let links = ExternalLinks()
        links.receive([URL(string: "https://a.example")!, URL(string: "file:///tmp/x")!, URL(string: "https://b.example")!])
        XCTAssertEqual(links.pending.map(\.host), ["a.example", "b.example"])
        XCTAssertEqual(links.take().count, 2)
        XCTAssertTrue(links.pending.isEmpty)
    }

    @MainActor func testReceivingShowsTheMainWindowAndIgnoresNonWebLinks() {
        let links = ExternalLinks()
        var shown = 0
        links.showMain = {shown += 1}
        links.receive([URL(string: "file:///tmp/x")!])
        XCTAssertEqual(shown, 0)
        links.receive([URL(string: "https://a.example")!])
        XCTAssertEqual(shown, 1)
        _ = links.take()
    }

}
