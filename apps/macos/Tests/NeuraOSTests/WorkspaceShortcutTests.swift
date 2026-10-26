import XCTest
import AppKit
@testable import NeuraOS

private final class ShortcutTestWindow: NSWindow {
    var testSheetParent: NSWindow?
    var testAttachedSheet: NSWindow?
    override var sheetParent: NSWindow? {testSheetParent}
    override var attachedSheet: NSWindow? {testAttachedSheet}
}

final class WorkspaceShortcutTests: XCTestCase {
    @MainActor func testCommandsRejectBothSidesOfSheetAndMissingKeyWindow() {
        let parent = ShortcutTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = ShortcutTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertFalse(WorkspaceCommandContext.allowsCommands(in: nil))
        XCTAssertTrue(WorkspaceCommandContext.allowsCommands(in: parent))
        parent.testAttachedSheet = sheet
        sheet.testSheetParent = parent
        XCTAssertFalse(WorkspaceCommandContext.allowsCommands(in: parent))
        XCTAssertFalse(WorkspaceCommandContext.allowsCommands(in: sheet))
        parent.testAttachedSheet = nil
        sheet.testSheetParent = nil
        XCTAssertTrue(WorkspaceCommandContext.allowsCommands(in: parent))
    }

    private func terminal(_ id: String, status: String = "running") -> TerminalRecord {
        TerminalRecord(id: id, workspaceId: "workspace", provider: "codex", status: status, cols: 100, rows: 30)
    }

    func testLateAutomaticTerminalsAppearOnceAndClosedTabsStayClosed() {
        var layout = WorkspaceTabState()
        var seen: Set<String> = []
        layout.reconcileTerminals([], seen: &seen, startingTabs: [])
        layout.reconcileTerminals([terminal("late")], seen: &seen, startingTabs: [])
        XCTAssertEqual(layout.tabs.map(\.terminalId), ["late"])
        XCTAssertEqual(layout.selectedId, layout.tabs.first?.id)
        let selected = layout.selectedId
        // Even a CLI which exits before the next poll must remain accessible.
        let records = [terminal("late"), terminal("quick-exit", status: "exited")]
        layout.reconcileTerminals(records, seen: &seen, startingTabs: [])
        XCTAssertEqual(layout.selectedId, selected)
        XCTAssertEqual(layout.tabs.map(\.number), [1, 2])
        layout.reconcileTerminals(records, seen: &seen, startingTabs: [])
        XCTAssertEqual(layout.tabs.count, 2)
        layout.tabs.removeLast()
        layout.reconcileTerminals(records, seen: &seen, startingTabs: [])
        XCTAssertEqual(layout.tabs.count, 1)
    }

    func testManualLaunchBindingWinsBeforeLateSessionsAreReconciled() {
        let manual = WorkspaceTab(kind: "codex")
        var layout = WorkspaceTabState(tabs: [manual], selectedId: manual.id)
        var seen: Set<String> = []
        let records = [terminal("manual"), terminal("automatic")]
        layout.reconcileTerminals(records, seen: &seen, startingTabs: [manual.id])
        XCTAssertEqual(layout.tabs.count, 1)
        XCTAssertTrue(seen.isEmpty)
        layout.tabs[0].terminalId = "manual"
        layout.reconcileTerminals(records, seen: &seen, startingTabs: [])
        XCTAssertEqual(layout.tabs.map(\.terminalId), ["manual", "automatic"])
        XCTAssertEqual(layout.selectedId, manual.id)
        // A launch in an unrelated workspace cannot block reconciliation.
        layout.reconcileTerminals(records + [terminal("another")], seen: &seen, startingTabs: ["unrelated-tab"])
        XCTAssertEqual(layout.tabs.count, 3)
    }

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
