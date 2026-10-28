import XCTest
import AppKit
import SwiftUI
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
        XCTAssertNil(layout.selectedId)
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

    func testLegacyAgentTabsMigrateToHomeWithoutClosingWork() throws {
        let work = WorkspaceTab(kind: "codex", terminalId: "running")
        let agents = WorkspaceTab(kind: "agents")
        var layout = WorkspaceTabState(tabs: [work, agents], selectedId: agents.id)
        layout.migrateAgentTabs()
        XCTAssertEqual(layout.tabs, [work])
        XCTAssertNil(layout.selectedId)
        let restored = try JSONDecoder().decode(WorkspaceTabState.self, from: JSONEncoder().encode(layout))
        XCTAssertNil(restored.selectedId)
        XCTAssertEqual(restored.tabs, [work])

        layout = WorkspaceTabState(tabs: [work, agents], selectedId: work.id)
        layout.migrateAgentTabs()
        XCTAssertEqual(layout.selectedId, work.id)
    }

    func testHomeRemainsSelectedWhenBackgroundTerminalArrives() {
        let work = WorkspaceTab(kind: "codex", terminalId: "existing")
        var layout = WorkspaceTabState(tabs: [work])
        var seen: Set<String> = ["existing"]
        layout.reconcileTerminals([terminal("existing"), terminal("new")], seen: &seen, startingTabs: [])
        XCTAssertNil(layout.selectedId)
        XCTAssertEqual(layout.tabs.count, 2)
        layout.moveSelection(by: 1)
        XCTAssertEqual(layout.selectedId, work.id)
    }

    @MainActor func testDelayedLaunchSurvivesEarlierTabRemovalAndReordering() async {
        let first = WorkspaceTab(kind: "shell", terminalId: "first")
        let target = WorkspaceTab(kind: "codex")
        let last = WorkspaceTab(kind: "shell", terminalId: "last")
        var layout = WorkspaceTabState(tabs: [first, target, last], selectedId: target.id)
        let state = Binding(get: {layout}, set: {layout = $0})
        let binding = state.tabValue(target.id, \.terminalId)
        let complete = Task { @MainActor in
            await Task.yield()
            await TerminalLaunchCompletion.attach(self.terminal("launched"), to: binding) {_ in
                XCTFail("A surviving owner must retain its terminal")
            }
        }
        layout.tabs.removeFirst()
        layout.tabs.reverse()
        await complete.value
        XCTAssertEqual(layout.tabs.first(where: {$0.id == target.id})?.terminalId, "launched")
        XCTAssertEqual(layout.tabs.first(where: {$0.id == last.id})?.terminalId, "last")
        XCTAssertEqual(layout.selectedId, target.id)
    }

    @MainActor func testDelayedLaunchAfterOwnerRemovalStopsOnlyItsTerminal() async {
        let target = WorkspaceTab(kind: "codex")
        let survivor = WorkspaceTab(kind: "codex", terminalId: "surviving")
        var layout = WorkspaceTabState(tabs: [target, survivor])
        let state = Binding(get: {layout}, set: {layout = $0})
        let binding = state.tabValue(target.id, \.terminalId)
        var stopped: [String] = []
        let complete = Task { @MainActor in
            await Task.yield()
            await TerminalLaunchCompletion.attach(self.terminal("orphan"), to: binding) {
                stopped.append($0.id)
            }
        }
        layout.tabs.removeFirst()
        await complete.value
        XCTAssertNil(binding.wrappedValue)
        XCTAssertEqual(stopped, ["orphan"])
        XCTAssertEqual(layout.tabs, [survivor])
    }

    @MainActor func testLateBindingsAreSafeAfterAllTabsCloseAndReplacementOpens() {
        let old = WorkspaceTab(kind: "browser", browserTitle: "Old")
        var layout = WorkspaceTabState(tabs: [old])
        let state = Binding(get: {layout}, set: {layout = $0})
        let title = state.tabValue(old.id, \.browserTitle)
        let terminal = state.tabValue(old.id, \.terminalId)
        layout.tabs.removeAll()
        XCTAssertNil(title.wrappedValue)
        terminal.wrappedValue = "late"
        title.wrappedValue = "late title"
        XCTAssertTrue(layout.tabs.isEmpty)
        let replacement = WorkspaceTab(kind: "browser", browserTitle: "New")
        layout.tabs.append(replacement)
        title.wrappedValue = "stale callback"
        XCTAssertEqual(layout.tabs, [replacement])
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
