import XCTest
@testable import NeuraOS

final class FixedTabTests: XCTestCase {
    @MainActor func testFixedTabsBelongToASpaceOrToAllOfThemAndSurviveReload() throws {
        let suite = "FixedTabTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let spaces = [SidebarSpace(id: "work", name: "仕事"), SidebarSpace(id: "home", name: "個人")]
        let store = FixedTabs(defaults: defaults)
        let linear = store.add(FixedTab(kind: "browser", title: "  ", url: "https://linear.app/team", spaceId: "work"))
        // An empty name falls back to the site, or to the kind for a terminal.
        XCTAssertEqual(linear.title, "linear.app")
        let agent = store.add(FixedTab(kind: "claude", title: "調べもの係", spaceId: nil, workspaceId: "root", terminalId: "t1"))
        let shell = store.add(FixedTab(kind: "shell", title: "", spaceId: "gone", workspaceId: "root"))
        XCTAssertEqual(shell.title, "Terminal")
        XCTAssertEqual(store.global.map(\.id), [agent.id])
        // A tab whose Space was deleted is shown in the first Space rather than lost.
        XCTAssertEqual(store.tabs(in: "work", spaces: spaces).map(\.id), [linear.id, shell.id])
        XCTAssertTrue(store.tabs(in: "home", spaces: spaces).isEmpty)
        XCTAssertTrue(store.owns(terminal: "t1"))
        XCTAssertEqual(store.tab(owning: "t1")?.id, agent.id)
        XCTAssertNil(store.tab(owning: "t2"))
        XCTAssertFalse(store.owns(terminal: "t2"))
        XCTAssertEqual(store.startingTabIds(in: "root"), [agent.id, shell.id])

        store.update(shell.id) {$0.spaceId = "work"; $0.terminalId = "t2"}
        store.move(shell.id, before: linear.id)
        // Reordering never crosses between the shared row and a Space's list.
        store.move(agent.id, before: linear.id)
        store.terminalBinding(agent.id).wrappedValue = nil
        let reloaded = FixedTabs(defaults: defaults)
        XCTAssertEqual(reloaded.tabs.map(\.id), [shell.id, linear.id, agent.id])
        XCTAssertEqual(reloaded.tab(shell.id)?.terminalId, "t2")
        XCTAssertNil(reloaded.tab(agent.id)?.terminalId)
        XCTAssertTrue(reloaded.owns(terminal: "t2"))
        reloaded.remove(linear.id)
        XCTAssertEqual(FixedTabs(defaults: defaults).tabs.map(\.id), [shell.id, agent.id])
    }

    @MainActor func testAFixedTabCoversTheWorktreeWithoutDeselectingIt() {
        let model = AppModel(startPolling: false)
        model.selectedId = "worktree"
        XCTAssertEqual(model.frontId, "worktree")
        let tab = FixedTabs.shared.add(FixedTab(kind: "shell", title: "test-\(UUID().uuidString)", workspaceId: "worktree"))
        defer {FixedTabs.shared.remove(tab.id)}
        model.openFixed(tab.id)
        XCTAssertEqual(model.fixedId, tab.id)
        XCTAssertNil(model.frontId)
        XCTAssertEqual(model.selectedId, "worktree")
        // Putting a terminal away keeps it alive; a page would be unloaded.
        model.closeFixed(tab.id, unload: false)
        XCTAssertNil(model.fixedId)
        XCTAssertTrue(model.openedFixedIds.contains(tab.id))
        XCTAssertEqual(model.frontId, "worktree")
        model.openFixed(tab.id)
        // Choosing a worktree brings it back to the front.
        model.select("worktree")
        XCTAssertNil(model.fixedId)
        model.openFixed(tab.id)
        model.removeFixed(tab.id)
        XCTAssertNil(model.fixedId)
        XCTAssertFalse(model.openedFixedIds.contains(tab.id))
        model.openFixed("missing")
        XCTAssertNil(model.fixedId)
    }

    @MainActor func testRightSidebarToggleActsOnTheAutomaticHideWhileItApplies() {
        let model = AppModel(startPolling: false)
        let shown = model.showInspector
        defer {model.showInspector = shown}
        model.showInspector = true
        XCTAssertTrue(model.inspectorShown)
        model.inspectorAutoHidden = true
        XCTAssertFalse(model.inspectorShown)
        // The toggle reveals it for now and leaves the user's standing choice alone.
        model.toggleInspector()
        XCTAssertTrue(model.inspectorShown)
        XCTAssertTrue(model.showInspector)
        model.toggleInspector()
        XCTAssertFalse(model.inspectorShown)
        model.inspectorAutoHidden = false
        model.toggleInspector()
        XCTAssertFalse(model.showInspector)
    }

    func testCommandBarFindsFixedTabsAndWorktrees() {
        let fixed = [FixedTab(id: "f1", kind: "browser", title: "Linear", url: "https://linear.app/team", spaceId: "work"),
                     FixedTab(id: "f2", kind: "claude", title: "調べもの係", workspaceId: "root")]
        let workspaces = [CommandBarWorkspace(id: "w2", title: "ログイン画面の修正", detail: "connect")]
        var context = CommandBarContext(workspaceId: "w1", fixed: fixed, workspaces: workspaces)
        XCTAssertTrue(CommandBarResults.items(query: "", context: context, history: []).contains {$0.action == .openFixed("f1")})
        XCTAssertEqual(CommandBarResults.items(query: "調べ", context: context, history: []).dropFirst().first?.action, .openFixed("f2"))
        XCTAssertTrue(CommandBarResults.items(query: "claude", context: context, history: []).contains {$0.action == .openFixed("f2")})
        XCTAssertTrue(CommandBarResults.items(query: "ログイン", context: context, history: []).contains {$0.action == .focusWorkspace("w2")})
        XCTAssertTrue(CommandBarResults.items(query: "connect", context: context, history: []).contains {$0.action == .focusWorkspace("w2")})
        // With no worktree to run in, the launchers are not offered.
        context.canLaunch = false
        XCTAssertFalse(CommandBarResults.items(query: "", context: context, history: []).contains {$0.action == .add("shell")})
        XCTAssertFalse(CommandBarResults.items(query: "term", context: context, history: []).contains {$0.action == .add("shell")})
    }
}
