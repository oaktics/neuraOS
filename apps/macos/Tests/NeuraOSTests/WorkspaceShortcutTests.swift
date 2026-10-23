import XCTest
@testable import NeuraOS

final class WorkspaceShortcutTests: XCTestCase {
    func testNavigationWrapsWithoutChangingTabIdentity() {
        let tabs = [WorkspaceTab(kind: "codex"), WorkspaceTab(kind: "shell"), WorkspaceTab(kind: "browser")]
        var layout = WorkspaceTabState(tabs: tabs, selectedId: tabs[0].id)
        layout.moveSelection(by: -1)
        XCTAssertEqual(layout.selectedId, tabs[2].id)
        layout.moveSelection(by: 1)
        XCTAssertEqual(layout.selectedId, tabs[0].id)
        layout.moveSelection(by: 1)
        XCTAssertEqual(layout.selectedId, tabs[1].id)
        XCTAssertEqual(layout.tabs, tabs)
    }

    func testNumberNineSelectsLastAndMissingNumbersAreIgnored() {
        let tabs = (0..<12).map {WorkspaceTab(kind: "shell", number: $0 + 1)}
        var layout = WorkspaceTabState(tabs: tabs, selectedId: tabs[0].id)
        layout.select(number: 9)
        XCTAssertEqual(layout.selectedId, tabs.last?.id)
        layout.select(number: 2)
        XCTAssertEqual(layout.selectedId, tabs[1].id)
        layout.tabs = Array(tabs.prefix(2))
        layout.select(number: 3)
        layout.select(number: 0)
        XCTAssertEqual(layout.selectedId, tabs[1].id)
    }

    func testEmptyAndStaleSelectionAreSafe() {
        var layout = WorkspaceTabState()
        layout.moveSelection(by: -1)
        layout.select(number: 9)
        XCTAssertNil(layout.selectedId)
        let tab = WorkspaceTab(kind: "shell")
        layout.tabs = [tab]
        layout.selectedId = "removed"
        layout.moveSelection(by: 1)
        XCTAssertEqual(layout.selectedId, tab.id)
    }
}
