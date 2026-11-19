import XCTest
@testable import NeuraOS

@MainActor
final class TabStripTests: XCTestCase {
    private func state(_ count: Int) -> WorkspaceTabState {
        WorkspaceTabState(tabs: (0..<count).map {WorkspaceTab(id: "t\($0)", kind: "shell", number: $0 + 1)})
    }

    func testDraggedTabTakesANeighboursPlaceAfterCoveringHalfOfIt() {
        let widths: [CGFloat] = [100, 100, 100, 100]
        var drag = TabStripDrag(id: "t2", origin: 200)
        XCTAssertEqual(drag.target(widths: widths, index: 2), 2)
        XCTAssertEqual(drag.offset(widths: widths, index: 2), 0)
        drag.translation = -49
        XCTAssertEqual(drag.target(widths: widths, index: 2), 2)
        drag.translation = -51
        XCTAssertEqual(drag.target(widths: widths, index: 2), 1)
        // Once moved, the same pointer position keeps it there and it is still drawn under the pointer.
        XCTAssertEqual(drag.target(widths: widths, index: 1), 1)
        XCTAssertEqual(drag.offset(widths: widths, index: 1), 49)
        drag.translation = 51
        XCTAssertEqual(drag.target(widths: widths, index: 2), 3)
        XCTAssertEqual(drag.offset(widths: widths, index: 3), -49)
    }

    func testDraggedTabStaysInsideTheStripAndRespectsUnevenWidths() {
        let widths: [CGFloat] = [60, 300, 80]
        var drag = TabStripDrag(id: "t2", origin: 360)
        drag.translation = 500
        XCTAssertEqual(drag.edge(widths: widths, index: 2), 360)
        drag.translation = -149
        XCTAssertEqual(drag.target(widths: widths, index: 2), 2)
        drag.translation = -151
        XCTAssertEqual(drag.target(widths: widths, index: 2), 1)
        drag.translation = -5000
        XCTAssertEqual(drag.edge(widths: widths, index: 2), 0)
        XCTAssertEqual(drag.target(widths: widths, index: 2), 0)
    }

    func testMovingAmongListedTabsSkipsPinnedPages() {
        var layout = state(4)
        layout.tabs[1].pinId = "pin"
        XCTAssertEqual(layout.listed.map(\.id), ["t0", "t2", "t3"])
        layout.move("t3", toListed: 0)
        XCTAssertEqual(layout.listed.map(\.id), ["t3", "t0", "t2"])
        layout.move("t3", toListed: 2)
        XCTAssertEqual(layout.listed.map(\.id), ["t0", "t2", "t3"])
        layout.move("t0", toListed: 9)
        XCTAssertEqual(layout.listed.map(\.id), ["t2", "t3", "t0"])
        layout.move("t2", toListed: 0)
        XCTAssertEqual(layout.listed.map(\.id), ["t2", "t3", "t0"])
        XCTAssertEqual(layout.tabs.count, 4)
        XCTAssertEqual(layout.listed(after: "t3").map(\.id), ["t0"])
        XCTAssertTrue(layout.listed(after: "t0").isEmpty)
    }

    func testClosedPagesAndFilesReopenWhereTheyWere() throws {
        let defaults = UserDefaults(suiteName: "tab-strip-\(UUID().uuidString)")!
        var layout = state(2)
        XCTAssertTrue(layout.openBrowser(URL(string: "https://example.com/a")!, workspaceId: "w", defaults: defaults))
        layout.openFile("notes.md")
        let page = try XCTUnwrap(layout.tabs.first {$0.kind == "browser"})
        layout.move(page.id, toListed: 1)
        XCTAssertEqual(layout.listed.map(\.kind), ["shell", "browser", "shell", "file"])
        XCTAssertFalse(layout.canReopen)
        // A terminal cannot be brought back, so closing one leaves nothing to reopen.
        layout.close("t0")
        XCTAssertFalse(layout.canReopen)
        layout.close(page.id)
        layout.close(try XCTUnwrap(layout.tabs.first {$0.kind == "file"}).id)
        XCTAssertEqual(layout.listed.map(\.kind), ["shell"])
        layout.reopenClosed(workspaceId: "w", defaults: defaults)
        XCTAssertEqual(layout.listed.map(\.kind), ["shell", "file"])
        XCTAssertEqual(layout.active?.filePath, "notes.md")
        layout.reopenClosed(workspaceId: "w", defaults: defaults)
        XCTAssertEqual(layout.listed.map(\.kind), ["browser", "shell", "file"])
        XCTAssertEqual(layout.active?.browserURL, "https://example.com/a")
        XCTAssertFalse(layout.canReopen)
        // Moving a page to the sidebar is not closing it.
        layout.close(try XCTUnwrap(layout.active).id, reopenable: false)
        XCTAssertFalse(layout.canReopen)
        let restored = try JSONDecoder().decode(WorkspaceTabState.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored.tabs, layout.tabs)
    }
}
