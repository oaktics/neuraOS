import XCTest
import AppKit
@testable import NeuraOS

final class BrowserWorkspaceTests: XCTestCase {
    func testTypedTextBecomesAnAddressOrASearch() {
        XCTAssertEqual(BrowserInput.resolve(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserInput.resolve("https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        // Development servers are plain HTTP.
        XCTAssertEqual(BrowserInput.resolve("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserInput.resolve("localhost:5173/admin")?.absoluteString, "http://localhost:5173/admin")
        XCTAssertEqual(BrowserInput.resolve("127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(BrowserInput.resolve("app.localhost:3000")?.absoluteString, "http://app.localhost:3000")
        XCTAssertEqual(BrowserInput.resolve("about:blank")?.absoluteString, "about:blank")
        XCTAssertEqual(BrowserInput.resolve("swift concurrency")?.absoluteString, "https://www.google.com/search?q=swift%20concurrency")
        XCTAssertEqual(BrowserInput.resolve("C++ & Rust?")?.absoluteString, "https://www.google.com/search?q=C%2B%2B%20%26%20Rust%3F")
        XCTAssertEqual(BrowserInput.resolve("日本語 検索")?.host, "www.google.com")
        // File names and version numbers are searches, not hosts.
        for text in ["index.ts", "package.json", "3.14", "node", "foo:bar"] {
            XCTAssertTrue(BrowserInput.isSearch(text), text)
            XCTAssertEqual(BrowserInput.resolve(text)?.host, "www.google.com", text)
        }
        XCTAssertEqual(BrowserInput.resolve("docs.rs")?.absoluteString, "https://docs.rs")
        XCTAssertEqual(BrowserInput.resolve("package.json/x")?.absoluteString, "https://package.json/x")
        // Never loaded, and never forwarded to a search engine either.
        for text in ["", "   ", "file:///etc/passwd", "https://user:secret@example.com", "chrome://settings"] {
            XCTAssertNil(BrowserInput.resolve(text), text)
        }
        XCTAssertEqual(BrowserInput.displayHost("https://www.example.com/a"), "example.com")
        XCTAssertEqual(BrowserInput.displayHost("http://localhost:3000/x"), "localhost:3000")
    }

    private func state(_ kinds: [String]) -> WorkspaceTabState {
        var state = WorkspaceTabState()
        for kind in kinds {state.tabs.append(WorkspaceTab(id: "\(kind)\(state.tabs.count)", kind: kind))}
        return state
    }

    @MainActor func testLinksOpenBesideTheirOpenerAndClosingReturnsThere() throws {
        let suite = "BrowserWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        var layout = state(["claude", "shell", "browser"])
        layout.focus("claude0")
        XCTAssertTrue(layout.openBrowser(URL(string: "https://a.example/")!, workspaceId: "w", defaults: defaults, opener: "claude0"))
        let first = try XCTUnwrap(layout.selectedId)
        XCTAssertEqual(layout.tabs.map(\.id), ["claude0", first, "shell1", "browser2"])
        // Background tabs queue up after the opener without taking focus.
        XCTAssertTrue(layout.openBrowser(URL(string: "https://b.example/")!, workspaceId: "w", defaults: defaults, opener: first, placement: .background))
        XCTAssertTrue(layout.openBrowser(URL(string: "https://c.example/")!, workspaceId: "w", defaults: defaults, opener: first, placement: .background))
        XCTAssertEqual(layout.selectedId, first)
        XCTAssertEqual(layout.tabs.map(\.browserURL), [nil, "https://a.example/", "https://b.example/", "https://c.example/", nil, nil])
        let second = layout.tabs[2].id
        // The page just opened in the background is the next recent-tab target.
        XCTAssertEqual(layout.recentOrder.prefix(2), [first, layout.tabs[3].id])
        layout.close(first)
        XCTAssertEqual(layout.selectedId, "claude0")
        // Its children now belong to the tab it came from.
        XCTAssertEqual(layout.tabs.first {$0.id == second}?.openerId, "claude0")
        layout.focus("browser2")
        layout.close("browser2")
        XCTAssertEqual(layout.selectedId, "shell1")
        // A typed address has no opener and goes to the end.
        XCTAssertTrue(layout.openBrowser(URL(string: "https://d.example/")!, workspaceId: "w", defaults: defaults))
        XCTAssertEqual(layout.tabs.last?.id, layout.selectedId)
    }

    @MainActor func testSplitKeepsTheConversationVisible() throws {
        let suite = "BrowserSplitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        var layout = state(["claude", "shell"])
        layout.focus("claude0")
        XCTAssertTrue(layout.openBrowser(URL(string: "http://localhost:3000")!, workspaceId: "w", defaults: defaults, opener: "claude0", placement: .split))
        let page = try XCTUnwrap(layout.split?.id)
        XCTAssertEqual(layout.selectedId, "claude0")
        XCTAssertEqual(layout.activeId, page)
        // Choosing the right pane's tab focuses it; another tab replaces only the left pane.
        layout.focus("shell1")
        XCTAssertEqual(layout.selectedId, "shell1")
        XCTAssertEqual(layout.split?.id, page)
        XCTAssertEqual(layout.activeId, "shell1")
        layout.focus(page)
        XCTAssertEqual(layout.selectedId, "shell1")
        XCTAssertEqual(layout.activeId, page)
        // Closing the left pane lets the page take the whole area.
        layout.close("shell1")
        XCTAssertEqual(layout.selectedId, page)
        XCTAssertNil(layout.split)
        // Splitting the only visible tab brings the previous one back on the left.
        layout.toggleSplit(page)
        XCTAssertEqual(layout.selectedId, "claude0")
        XCTAssertEqual(layout.split?.id, page)
        layout.toggleSplit(page)
        XCTAssertNil(layout.split)
        XCTAssertEqual(layout.selectedId, "claude0")
        // A link opened from a conversation shows on the right but leaves commands with the conversation.
        layout.toggleSplit(page); layout.focus("claude0")
        XCTAssertTrue(layout.openBrowser(URL(string: "https://docs.example/")!, workspaceId: "w", defaults: defaults, opener: "claude0", placement: .split, focusSplit: false))
        XCTAssertEqual(layout.activeId, "claude0")
        XCTAssertEqual(layout.split?.browserURL, "https://docs.example/")
        XCTAssertEqual(layout.recentOrder.prefix(2).last, layout.split?.id)
        layout.close(layout.split!.id)
        // The diff surface cannot be moved to the right pane.
        layout.tabs.append(WorkspaceTab(id: "diff", kind: "diff")); layout.focus("diff")
        layout.toggleSplit("diff")
        XCTAssertNil(layout.split)
        layout.close("diff")
        layout.focus("claude0")
        // Closing the right pane never changes the left one.
        layout.toggleSplit(page)
        layout.close(page)
        XCTAssertNil(layout.splitId)
        XCTAssertEqual(layout.selectedId, "claude0")
        XCTAssertEqual(layout.activeId, "claude0")
    }

    func testSavedLayoutsFromEarlierVersionsStillLoad() throws {
        let old = #"{"tabs":[{"id":"a","kind":"browser","number":1,"browserTitle":"Docs"},{"id":"b","kind":"shell","number":1}],"selectedId":"a"}"#
        var layout = try JSONDecoder().decode(WorkspaceTabState.self, from: Data(old.utf8))
        layout.normalize()
        XCTAssertEqual(layout.tabs.map(\.id), ["a", "b"])
        XCTAssertEqual(layout.activeId, "a")
        XCTAssertNil(layout.split)
        // A split pointing at a tab that no longer exists is dropped.
        layout.splitId = "gone"; layout.splitFocused = true
        layout.normalize()
        XCTAssertNil(layout.splitId)
        XCTAssertEqual(layout.activeId, "a")
    }

    func testRecentTabCycleWalksBackUntilControlIsReleased() {
        var layout = state(["claude", "shell", "browser"])
        for id in ["claude0", "shell1", "browser2"] {layout.focus(id)}
        var cycle = RecentTabCycle()
        // One press toggles to the previous tab.
        XCTAssertEqual(cycle.step(1, in: layout), "shell1")
        layout.focus("shell1", record: false)
        // Held: a second press goes one further back instead of bouncing.
        XCTAssertEqual(cycle.step(1, in: layout), "claude0")
        layout.focus("claude0", record: false)
        XCTAssertEqual(cycle.step(-1, in: layout), "shell1")
        cycle.finish(); layout.focus("shell1", record: false); layout.touch(layout.activeId)
        XCTAssertEqual(layout.recentOrder, ["shell1", "browser2", "claude0"])
        var next = RecentTabCycle()
        XCTAssertEqual(next.step(1, in: layout), "browser2")
        var single = RecentTabCycle()
        var one = state(["shell"]); one.focus("shell0")
        XCTAssertNil(single.step(1, in: one))
        XCTAssertFalse(single.active)
        // From the home surface the first step is the tab used last, even if it is the only one.
        var home = RecentTabCycle()
        layout.focus(nil)
        XCTAssertEqual(home.step(1, in: layout), "shell1")
        XCTAssertEqual(home.step(1, in: layout), "browser2")
        var onlyTab = RecentTabCycle()
        XCTAssertEqual(onlyTab.step(1, in: state(["shell"])), "shell0")
    }

    func testCommandBarOffersTheTypedDestinationFirst() throws {
        let tabs = [CommandBarTab(workspaceId: "w", workspaceName: "app / main", tabId: "t1", title: "Pull requests", url: "https://github.com/org/repo/pulls"),
                    CommandBarTab(workspaceId: "other", workspaceName: "app / fix", tabId: "t2", title: "Preview", url: "http://localhost:3000/")]
        let fixed = [FixedTab(id: "p", kind: "browser", title: "Repo", url: "https://github.com/org/repo", projectId: "project")]
        let context = CommandBarContext(workspaceId: "w", conversationProvider: "claude", tabs: tabs, fixed: fixed)
        // Empty: Return opens a terminal, as ⌘T did before the command bar existed.
        let empty = CommandBarResults.items(query: "", context: context)
        XCTAssertEqual(empty.first?.action, .add("shell"))
        XCTAssertEqual(empty.dropFirst().first?.action, .add("claude"))
        XCTAssertTrue(empty.contains {$0.action == .openFixed("p")})
        XCTAssertTrue(empty.contains {$0.action == .focusTab(workspaceId: "w", tabId: "t1")})
        XCTAssertFalse(empty.contains {$0.action == .focusTab(workspaceId: "other", tabId: "t2")})
        let typed = CommandBarResults.items(query: "localhost:3000", context: context)
        XCTAssertEqual(typed.first?.action, .open(URL(string: "http://localhost:3000")!))
        // The tab already showing it, in another worktree, is one step away.
        XCTAssertEqual(typed.dropFirst().first?.action, .focusTab(workspaceId: "other", tabId: "t2"))
        XCTAssertEqual(typed.dropFirst().first?.detail, "app / fix · localhost:3000")
        let search = CommandBarResults.items(query: "github", context: context)
        XCTAssertEqual(search.first?.detail, "Googleで検索")
        // The matching destination is listed once.
        XCTAssertEqual(search.filter {$0.address == "https://github.com/org/repo"}.count, 1)
        XCTAssertEqual(CommandBarResults.items(query: "term", context: context).last?.action, .add("shell"))
        var editing = context; editing.editing = true; editing.currentURL = "https://github.com/org/repo/pulls"
        XCTAssertEqual(CommandBarResults.items(query: editing.currentURL, context: editing).first?.hint, "再読み込み")
        XCTAssertEqual(CommandBarResults.items(query: "docs.rs", context: editing).first?.action, .navigate(URL(string: "https://docs.rs")!))
        XCTAssertFalse(CommandBarResults.items(query: "term", context: editing).contains {$0.action == .add("shell")})
        XCTAssertTrue(CommandBarResults.items(query: "file:///etc/passwd", context: context).isEmpty)
    }

    @MainActor func testGlobalKeysCloseTabsAndWalkRecentOnes() {
        func route(_ type: NSEvent.EventType, _ key: UInt16, _ text: String?, _ flags: NSEvent.ModifierFlags, tab: Bool = true) -> KeyboardRouter.Route? {
            KeyboardRouter.route(type: type, keyCode: key, characters: text, flags: flags, hasActiveTab: tab)
        }
        XCTAssertEqual(route(.keyDown, 13, "w", .command), .close)
        // On the home surface ⌘W keeps its window meaning.
        XCTAssertNil(route(.keyDown, 13, "w", .command, tab: false))
        XCTAssertNil(route(.keyDown, 13, "w", [.command, .shift]))
        XCTAssertEqual(route(.keyDown, 48, "\t", .control), .recent(1))
        XCTAssertEqual(route(.keyDown, 48, "\t", [.control, .shift]), .recent(-1))
        XCTAssertNil(route(.keyDown, 48, "\t", []))
        XCTAssertNil(route(.keyDown, 48, "\t", .command))
        XCTAssertEqual(route(.flagsChanged, 59, nil, []), .finishRecent)
        XCTAssertNil(route(.flagsChanged, 59, nil, .control))
        // Caps lock and function flags do not change the meaning of a key.
        XCTAssertEqual(route(.keyDown, 13, "W", [.command, .capsLock, .function]), .close)
    }
}

final class AppShortcutTests: XCTestCase {
    private func match(_ key: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) -> AppShortcut? {
        AppShortcut.match(key: key, keyCode: code, flags: flags)
    }

    func testShortcutsRoutedWhileAPageHasFocusMirrorTheMenuBar() {
        XCTAssertEqual(match("t", .command), .workspace(.commandBar(edit: false)))
        XCTAssertEqual(match("l", .command), .workspace(.commandBar(edit: true)))
        XCTAssertEqual(match("t", [.command, .control]), .workspace(.add("shell")))
        XCTAssertEqual(match("t", [.command, .shift]), .conversation)
        XCTAssertEqual(match("t", [.command, .option]), .workspace(.add("claude")))
        XCTAssertEqual(match("3", .command), .workspace(.select(3)))
        XCTAssertEqual(match("r", .command), .workspace(.browser(.reload)))
        XCTAssertEqual(match("r", [.command, .shift]), .workspace(.browser(.hardReload)))
        XCTAssertEqual(match("[", .command), .workspace(.browser(.back)))
        XCTAssertEqual(match("[", [.command, .shift]), .workspace(.move(-1)))
        XCTAssertEqual(match("f", .command), .workspace(.browser(.find)))
        XCTAssertEqual(match("c", [.command, .shift]), .workspace(.browser(.copyURL)))
        XCTAssertEqual(match("i", [.command, .option]), .workspace(.browser(.devTools)))
        XCTAssertEqual(match("g", [.command, .shift]), .workspace(.inspector("git")))
        XCTAssertEqual(match("g", [.command, .option]), .workspace(.inspector("github")))
        // US and JIS keyboards name these keys differently.
        for key in ["\\", "¥"] {
            XCTAssertEqual(match(key, .command), .workspace(.toggleSplit), key)
            XCTAssertEqual(match(key, [.command, .option]), .toggleInspector, key)
        }
        for key in ["=", "+", ";"] {XCTAssertEqual(match(key, .command), .workspace(.browser(.zoomIn)), key)}
        XCTAssertEqual(match("", [.command, .option], code: 123), .space(-1))
        XCTAssertEqual(match("", [.command, .option], code: 124), .space(1))
        XCTAssertEqual(match("s", [.command, .control]), .toggleSidebar)
        XCTAssertEqual(match("n", .command), .newWork)
        // Editing keys and anything unassigned stay with the page.
        for key in ["c", "v", "x", "a", "z", "k", "b", "s", "p"] {XCTAssertNil(match(key, .command), key)}
        XCTAssertNil(match("z", [.command, .shift]))
        XCTAssertNil(match("t", []))
        XCTAssertNil(match("t", .control))
        XCTAssertNil(match("t", [.command, .shift, .option]))
        // Caps lock does not change a shortcut.
        XCTAssertEqual(match("t", [.command, .capsLock]), .workspace(.commandBar(edit: false)))
    }

    @MainActor func testRoutedShortcutsKeepTheirMenuConditions() {
        let model = AppModel(startPolling: false)
        model.selectedId = nil
        // Nothing selected: tab and browser shortcuts stay with the page.
        XCTAssertFalse(model.perform(.workspace(.commandBar(edit: false))))
        XCTAssertFalse(model.perform(.workspace(.browser(.reload))))
        XCTAssertFalse(model.perform(.conversation))
        XCTAssertFalse(model.perform(.toggleInspector))
        let sidebar = model.showSidebar
        XCTAssertTrue(model.perform(.toggleSidebar))
        XCTAssertEqual(model.showSidebar, !sidebar)
        model.showSidebar = sidebar
    }
}
