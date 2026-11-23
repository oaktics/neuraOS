import SwiftUI

struct WorkspaceTab: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var kind: String
    var number = 1
    var terminalId: String?
    var browserTitle: String?
    var filePath: String?
    // The tab this one was opened from; closing returns there.
    var openerId: String?
    var browserURL: String?
    var title: String {
        if kind == "file", let filePath {return (filePath as NSString).lastPathComponent}
        if kind == "browser", let browserTitle, !browserTitle.isEmpty {return browserTitle}
        if kind == "browser", let browserURL, !browserURL.isEmpty, browserURL != "about:blank" {return BrowserInput.displayHost(browserURL)}
        let name = kind == "codex" ? "Codex" : kind == "claude" ? "Claude Code" : kind == "shell" ? "Terminal" : kind == "browser" ? "Browser" : kind == "files" ? "ファイル" : kind == "github" ? "GitHub" : "差分"
        return ["files", "diff", "github"].contains(kind) ? name : "\(name) \(number)"
    }
    func displayTitle(terminal: TerminalRecord?) -> String {
        if ["codex", "claude"].contains(kind), terminal?.id == terminalId,
           let name = terminal?.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {return name}
        return title
    }
    var icon: String {kind == "codex" ? "sparkle" : kind == "claude" ? "asterisk" : kind == "shell" ? "terminal" : kind == "browser" ? "globe" : ["file", "files"].contains(kind) ? "doc" : kind == "github" ? "arrow.triangle.pull" : "plus.forwardslash.minus"}
    var isTerminal: Bool {["codex", "claude", "shell"].contains(kind)}
}

/// A page or file tab that was closed, kept so it can be opened again where it was.
struct ClosedTab: Codable, Equatable {
    var kind: String
    /// The page address or the file path.
    var target: String
    /// Its place among the listed tabs.
    var index: Int
}

/// A tab being dragged along the strip. The others close up as if it were lifted
/// out, and it takes a neighbour's place once it has covered half of it.
struct TabStripDrag: Equatable {
    let id: String
    /// Leading edge of the tab when the drag began, measured from the strip's start.
    let origin: CGFloat
    var translation: CGFloat = 0

    /// Leading edge now, kept inside the strip. `widths` are in strip order; `index` is the tab's place.
    func edge(widths: [CGFloat], index: Int) -> CGFloat {
        min(max(0, origin + translation), max(0, widths.reduce(0, +) - widths[index]))
    }
    /// The place the tab belongs at.
    func target(widths: [CGFloat], index: Int) -> Int {
        let edge = edge(widths: widths, index: index)
        var start: CGFloat = 0, count = 0
        for (position, width) in widths.enumerated() where position != index {
            if start + width / 2 < edge {count += 1}
            start += width
        }
        return count
    }
    /// How far to draw the tab from where the layout puts it.
    func offset(widths: [CGFloat], index: Int) -> CGFloat {
        edge(widths: widths, index: index) - widths[..<index].reduce(0, +)
    }
}

struct WorkspaceTabState: Codable {
    var tabs: [WorkspaceTab] = []
    var selectedId: String?
    // The tab shown in the right pane, beside the selected one.
    var splitId: String?
    var splitFraction: Double?
    var splitFocused: Bool?
    // Most recently used first.
    var recent: [String]?
    // Most recently closed last.
    var closed: [ClosedTab]?

    /// The right pane's tab, when a split is really on screen.
    var split: WorkspaceTab? {
        guard let splitId, splitId != selectedId else {return nil}
        return tabs.first {$0.id == splitId}
    }
    /// The tab that keyboard commands apply to. Nil is the home surface.
    var activeId: String? {splitFocused == true ? split?.id ?? selectedId : selectedId}
    var active: WorkspaceTab? {tabs.first {$0.id == activeId}}
    var fraction: Double {min(0.8, max(0.2, splitFraction ?? 0.5))}
    /// Tabs listed in the tab strip.
    var listed: [WorkspaceTab] {tabs}

    // A nil selection is the permanent home surface, not a missing tab.
    mutating func migrateAgentTabs() {
        if tabs.contains(where: {$0.kind == "agents" && $0.id == selectedId}) {selectedId = nil}
        tabs.removeAll {$0.kind == "agents"}
    }

    /// Drop references to tabs that no longer exist.
    mutating func normalize() {
        if let selectedId, !tabs.contains(where: {$0.id == selectedId}) {self.selectedId = nil}
        if split == nil {splitId = nil; splitFocused = nil}
        if let recent {
            let ids = Set(tabs.map(\.id))
            self.recent = recent.filter {ids.contains($0)}
        }
    }

    /// Bring a tab to the front. The right pane's own tab only takes focus.
    mutating func focus(_ id: String?, record: Bool = true) {
        if let id, id == split?.id {
            splitFocused = true
        } else {
            selectedId = id
            splitFocused = false
            if splitId == id {splitId = nil}
        }
        if record {touch(id)}
    }

    mutating func touch(_ id: String?) {
        guard let id else {return}
        var order = recent ?? []
        order.removeAll {$0 == id}
        order.insert(id, at: 0)
        recent = Array(order.prefix(32))
    }

    /// Every tab, most recently used first; tabs never visited keep strip order at the end.
    var recentOrder: [String] {
        let ids = tabs.map(\.id)
        let known = (recent ?? []).filter {ids.contains($0)}
        return known + ids.filter {!known.contains($0)}
    }

    /// Show a tab beside the selected one, or return it to the strip.
    mutating func toggleSplit(_ id: String) {
        // The diff surface is drawn in the left pane only.
        guard let tab = tabs.first(where: {$0.id == id}), tab.kind != "diff" else {return}
        if splitId == id {splitId = nil; splitFocused = nil; return}
        if selectedId == id {
            // Keep the current tab on screen: it moves right and the previous one returns to the left.
            let previous = recentOrder.first {$0 != id}
            selectedId = previous
        }
        splitId = id
        splitFocused = true
        normalize()
        touch(id)
    }

    /// Index for a tab opened from `openerId`: beside it, after tabs it already opened in the background.
    func insertionIndex(after openerId: String?, background: Bool) -> Int {
        guard let openerId, let opener = tabs.firstIndex(where: {$0.id == openerId}) else {return tabs.count}
        guard background else {return opener + 1}
        var index = opener + 1
        while index < tabs.count, tabs[index].openerId == openerId {index += 1}
        return index
    }

    /// `focusSplit` false shows the page on the right but leaves commands with the current tab,
    /// which is where the keyboard still is when a link is opened from a conversation.
    mutating func insert(_ tab: WorkspaceTab, placement: BrowserPlacement = .tab, focusSplit: Bool = true) {
        tabs.insert(tab, at: min(tabs.count, insertionIndex(after: tab.openerId, background: placement == .background)))
        switch placement {
        case .tab: focus(tab.id)
        case .background:
            // The next recent-tab switch lands on the page the user just asked for.
            var order = recent ?? []
            order.insert(tab.id, at: min(1, order.count))
            recent = order
        case .split:
            splitId = tab.id
            if selectedId == tab.id {selectedId = nil}
            splitFocused = focusSplit
            if focusSplit {touch(tab.id)} else {
                var order = recent ?? []
                order.insert(tab.id, at: min(1, order.count))
                recent = order
            }
        }
    }

    @discardableResult
    @MainActor mutating func openBrowser(_ url: URL, workspaceId: String, defaults: UserDefaults = .standard,
                                         opener: String? = nil, placement: BrowserPlacement = .tab, focusSplit: Bool = true) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              BrowserModel.navigationURL(url.absoluteString) != nil else {return false}
        var tab = WorkspaceTab(kind: "browser", number: (tabs.filter {$0.kind == "browser"}.map(\.number).max() ?? 0) + 1)
        tab.openerId = opener
        tab.browserURL = url.absoluteString
        // Seed the URL before SwiftUI constructs the browser and starts navigation.
        defaults.set(url.absoluteString, forKey: "browser.\(workspaceId).\(tab.id)")
        insert(tab, placement: placement, focusSplit: focusSplit)
        return true
    }

    mutating func openFile(_ path: String) {
        if let existing = tabs.first(where: {$0.kind == "file" && $0.filePath == path}) {
            focus(existing.id)
        } else {
            let tab = WorkspaceTab(kind: "file", filePath: path)
            tabs.append(tab); focus(tab.id)
        }
    }

    /// Remove a tab and choose what the user sees next: where they came from, else a neighbour.
    mutating func close(_ id: String, reopenable: Bool = true) {
        guard let index = tabs.firstIndex(where: {$0.id == id}) else {return}
        if reopenable {remember(tabs[index])}
        let closed = tabs.remove(at: index)
        for position in tabs.indices where tabs[position].openerId == id {tabs[position].openerId = closed.openerId}
        recent?.removeAll {$0 == id}
        if splitId == id {
            splitId = nil; splitFocused = nil
        } else if selectedId == id {
            if let other = split {
                // The remaining pane takes the whole area.
                selectedId = other.id; splitId = nil; splitFocused = nil
            } else if let opener = closed.openerId, tabs.contains(where: {$0.id == opener}) {
                selectedId = opener
            } else {
                selectedId = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        }
        normalize()
    }

    private mutating func remember(_ tab: WorkspaceTab) {
        guard let index = listed.firstIndex(where: {$0.id == tab.id}) else {return}
        let target: String?
        switch tab.kind {
        case "browser": target = tab.browserURL.flatMap {["http", "https"].contains(URL(string: $0)?.scheme?.lowercased() ?? "") ? $0 : nil}
        case "file": target = tab.filePath
        default: target = nil
        }
        guard let target else {return}
        closed = Array(((closed ?? []) + [ClosedTab(kind: tab.kind, target: target, index: index)]).suffix(20))
    }

    var canReopen: Bool {closed?.isEmpty == false}

    /// Open the most recently closed page or file again, where it was.
    @MainActor mutating func reopenClosed(workspaceId: String, defaults: UserDefaults = .standard) {
        while let entry = closed?.popLast() {
            if entry.kind == "browser" {
                guard let url = URL(string: entry.target), openBrowser(url, workspaceId: workspaceId, defaults: defaults) else {continue}
            } else {
                openFile(entry.target)
            }
            if let id = activeId {move(id, toListed: entry.index)}
            return
        }
    }

    /// Tabs after this one in the strip.
    func listed(after id: String) -> [WorkspaceTab] {
        let visible = listed
        guard let index = visible.firstIndex(where: {$0.id == id}) else {return []}
        return Array(visible[(index + 1)...])
    }

    mutating func reconcileTerminals(_ terminals: [TerminalRecord], seen: inout Set<String>, startingTabs: Set<String>) {
        // A manual launch publishes its record before assigning the owning tab's
        // binding. Wait for that binding so we cannot create a duplicate tab.
        guard !tabs.contains(where: {startingTabs.contains($0.id)}) else {return}
        for terminal in terminals where !seen.contains(terminal.id) {
            if !tabs.contains(where: {$0.terminalId == terminal.id}) {
                let number = (tabs.filter {$0.kind == terminal.provider}.map(\.number).max() ?? 0) + 1
                tabs.append(WorkspaceTab(kind: terminal.provider, number: number, terminalId: terminal.id))
            }
        }
        seen.formUnion(terminals.map(\.id))
        normalize()
    }

    mutating func moveSelection(by offset: Int) {
        guard !tabs.isEmpty else {return}
        guard let index = tabs.firstIndex(where: {$0.id == activeId}) else {
            focus(offset < 0 ? tabs.last?.id : tabs.first?.id)
            return
        }
        let next = ((index + offset) % tabs.count + tabs.count) % tabs.count
        focus(tabs[next].id)
    }

    mutating func select(number: Int) {
        guard (1...9).contains(number) else {return}
        let visible = listed
        let index = number == 9 ? visible.count - 1 : number - 1
        guard visible.indices.contains(index) else {return}
        focus(visible[index].id)
    }

    mutating func move(_ id: String, before targetId: String?) {
        guard id != targetId, let source = tabs.firstIndex(where: {$0.id == id}) else {return}
        let tab = tabs.remove(at: source)
        let destination = targetId.flatMap {target in tabs.firstIndex(where: {$0.id == target})} ?? tabs.endIndex
        tabs.insert(tab, at: destination)
    }

    /// Put a tab at a place among the listed ones.
    mutating func move(_ id: String, toListed position: Int) {
        var visible = listed.map(\.id)
        guard let source = visible.firstIndex(of: id) else {return}
        visible.remove(at: source)
        let position = min(max(0, position), visible.count)
        guard position != source else {return}
        move(id, before: position < visible.count ? visible[position] : nil)
    }
}

extension Binding where Value == WorkspaceTabState {
    // Never retain an array-element binding across an async launch or browser callback.
    // Resolve the stable tab ID on every access; a removed tab becomes a no-op.
    func tabValue(_ id: String, _ keyPath: WritableKeyPath<WorkspaceTab, String?>) -> Binding<String?> {
        Binding<String?>(
            get: {wrappedValue.tabs.first(where: {$0.id == id})?[keyPath: keyPath]},
            set: {value in
                guard let index = wrappedValue.tabs.firstIndex(where: {$0.id == id}),
                      wrappedValue.tabs[index][keyPath: keyPath] != value else {return}
                wrappedValue.tabs[index][keyPath: keyPath] = value
            }
        )
    }
}

/// Recent-tab switching while Control stays held: each press walks one step
/// further back, and releasing Control makes the tab reached the most recent.
struct RecentTabCycle {
    private(set) var order: [String] = []
    private(set) var index = 0
    private var started = false
    var active: Bool {!order.isEmpty}

    mutating func step(_ offset: Int, in state: WorkspaceTabState) -> String? {
        if order.isEmpty {
            order = state.recentOrder
            // Start from the tab on screen even if it was never recorded.
            if let current = state.activeId, let position = order.firstIndex(of: current) {order.remove(at: position); order.insert(current, at: 0)}
            index = 0
        }
        // From the home surface the most recent tab is itself the first step.
        if state.activeId == nil, index == 0, !started {started = true; return order.first}
        started = true
        guard order.count > 1 else {order = []; started = false; return nil}
        index = ((index + offset) % order.count + order.count) % order.count
        return order[index]
    }

    mutating func finish() {order = []; index = 0; started = false}
}
