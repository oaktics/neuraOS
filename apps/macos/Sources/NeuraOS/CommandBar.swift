import SwiftUI
import AppKit
import ChromiumBridge

/// One row of the command bar and what choosing it does.
struct CommandBarItem: Identifiable, Equatable {
    enum Action: Equatable {
        /// Load in the current browser tab (editing its address).
        case navigate(URL)
        case open(URL)
        case focusTab(workspaceId: String, tabId: String)
        case add(String)
        case openFixed(String)
        case focusWorkspace(String)
    }
    var id: String
    var icon: String
    var address: String?
    var title: String
    var detail: String
    var hint: String
    var action: Action
}

/// An open browser tab in any worktree, as saved by its workspace.
struct CommandBarTab: Equatable {
    var workspaceId: String
    var workspaceName: String
    var tabId: String
    var title: String
    var url: String
}

struct CommandBarContext {
    /// Editing the current tab's address rather than opening a new tab.
    var editing = false
    var currentURL = ""
    var workspaceId = ""
    var conversationProvider = "codex"
    /// False when no worktree is selected to start a terminal or conversation in.
    var canLaunch = true
    var tabs: [CommandBarTab] = []
    var fixed: [FixedTab] = []
    var workspaces: [CommandBarWorkspace] = []
}

/// A worktree or folder that the command bar can switch to.
struct CommandBarWorkspace: Equatable {
    var id: String
    var title: String
    var detail: String
}

enum CommandBarResults {
    static let launchers: [(kind: String, title: String, icon: String, words: [String])] = [
        ("shell", "新しいTerminal", "terminal", ["terminal", "shell", "ターミナル", "たーみなる"]),
        ("claude", "新しいClaude Code", "asterisk", ["claude", "クロード"]),
        ("codex", "新しいCodex", "sparkle", ["codex", "コーデックス"]),
    ]

    /// Rows for the text typed so far. The first row is what Return does.
    static func items(query raw: String, context: CommandBarContext, history: [BrowserVisit]) -> [CommandBarItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = query.lowercased()
        var items: [CommandBarItem] = []
        func launcher(_ entry: (kind: String, title: String, icon: String, words: [String])) -> CommandBarItem {
            CommandBarItem(id: "add." + entry.kind, icon: entry.icon, title: entry.title, detail: "この作業フォルダで起動", hint: "起動", action: .add(entry.kind))
        }
        func tabRow(_ tab: CommandBarTab) -> CommandBarItem {
            CommandBarItem(id: "tab.\(tab.workspaceId).\(tab.tabId)", icon: "globe", address: tab.url,
                           title: tab.title.isEmpty ? BrowserInput.displayHost(tab.url) : tab.title,
                           detail: tab.workspaceId == context.workspaceId ? BrowserInput.displayHost(tab.url) : "\(tab.workspaceName) · \(BrowserInput.displayHost(tab.url))",
                           hint: "タブへ移動", action: .focusTab(workspaceId: tab.workspaceId, tabId: tab.tabId))
        }
        func visitRow(_ visit: BrowserVisit) -> CommandBarItem? {
            guard let url = URL(string: visit.url) else {return nil}
            return CommandBarItem(id: "visit." + visit.url, icon: "clock", address: visit.url,
                                  title: visit.title.isEmpty ? BrowserInput.displayHost(visit.url) : visit.title,
                                  detail: visit.url, hint: context.editing ? "移動" : "開く",
                                  action: context.editing ? .navigate(url) : .open(url))
        }
        func fixedRow(_ tab: FixedTab) -> CommandBarItem {
            CommandBarItem(id: "fixed." + tab.id, icon: tab.kind == "browser" ? "pin" : tab.icon, address: tab.url, title: tab.title,
                           detail: "固定タブ · " + (tab.url.map(BrowserInput.displayHost) ?? tab.kindName), hint: "開く", action: .openFixed(tab.id))
        }
        func workspaceRow(_ workspace: CommandBarWorkspace) -> CommandBarItem {
            CommandBarItem(id: "workspace." + workspace.id, icon: "arrow.triangle.branch", title: workspace.title, detail: workspace.detail,
                           hint: "作業へ移動", action: .focusWorkspace(workspace.id))
        }
        if query.isEmpty {
            if !context.editing, context.canLaunch {
                items.append(launcher(launchers[0]))
                if let entry = launchers.first(where: {$0.kind == context.conversationProvider}) {
                    var row = launcher(entry); row.title = "新しい会話（\(entry.kind == "claude" ? "Claude Code" : "Codex")）"
                    items.append(row)
                }
            }
            if !context.editing {items += context.fixed.prefix(6).map(fixedRow)}
            items += context.tabs.filter {$0.workspaceId == context.workspaceId}.prefix(6).map(tabRow)
            items += history.prefix(6).compactMap(visitRow)
            return unique(items)
        }
        if query != context.currentURL || !context.editing, let url = BrowserInput.resolve(query) {
            let search = BrowserInput.isSearch(query)
            items.append(CommandBarItem(id: "primary", icon: search ? "magnifyingglass" : "globe", address: search ? nil : url.absoluteString,
                                        title: search ? query : url.absoluteString, detail: search ? "Googleで検索" : "このアドレスを開く",
                                        hint: context.editing ? "移動" : "開く", action: context.editing ? .navigate(url) : .open(url)))
        } else if context.editing, let url = BrowserInput.resolve(query) {
            items.append(CommandBarItem(id: "primary", icon: "arrow.clockwise", address: url.absoluteString, title: url.absoluteString,
                                        detail: "現在のページ", hint: "再読み込み", action: .navigate(url)))
        }
        func matches(_ values: String...) -> Bool {values.contains {$0.lowercased().contains(needle)}}
        items += context.tabs.filter {matches($0.title, $0.url)}.prefix(5).map(tabRow)
        items += context.fixed.filter {matches($0.title, $0.url ?? "", $0.kindName)}.prefix(4).map(fixedRow)
        items += context.workspaces.filter {matches($0.title, $0.detail)}.prefix(5).map(workspaceRow)
        items += history.prefix(6).compactMap(visitRow)
        if !context.editing, context.canLaunch {
            items += launchers.filter {entry in matches(entry.title) || entry.words.contains {$0.hasPrefix(needle)}}.map(launcher)
        }
        return unique(items)
    }

    /// The same page reached two ways (open tab, pin, history) is listed once, at its best rank.
    private static func unique(_ items: [CommandBarItem]) -> [CommandBarItem] {
        var seen: Set<String> = [], addresses: Set<String> = [], result: [CommandBarItem] = []
        for item in items where seen.insert(item.id).inserted {
            if let address = item.address, item.id != "primary" {
                guard addresses.insert(address).inserted else {continue}
            } else if let address = item.address {addresses.insert(address)}
            result.append(item)
        }
        return result
    }
}

@MainActor final class CommandBarModel: ObservableObject {
    @Published var query = "" {didSet {if query != oldValue {refresh()}}}
    @Published private(set) var items: [CommandBarItem] = []
    @Published var selection = 0
    @Published var focus = 0
    var context = CommandBarContext()
    var onCommit: (CommandBarItem.Action, _ split: Bool) -> Void = {_, _ in}
    var onCancel: () -> Void = {}

    func begin(_ context: CommandBarContext) {
        self.context = context
        query = context.editing ? context.currentURL : ""
        refresh()
        focus += 1
    }
    func refresh() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = text == context.currentURL && context.editing ? [] : BrowserHistory.shared.search(text, limit: 8)
        items = CommandBarResults.items(query: query, context: context, history: history)
        selection = 0
    }
    func move(_ offset: Int) {
        guard !items.isEmpty else {return}
        selection = ((selection + offset) % items.count + items.count) % items.count
    }
    func commit(split: Bool = false) {
        guard items.indices.contains(selection) else {return}
        onCommit(items[selection].action, split)
    }
}

struct CommandBarView: View {
    @ObservedObject var model: CommandBarModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.context.editing ? "globe" : "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
                CommandBarField(text: $model.query, focus: model.focus,
                                placeholder: model.context.editing ? "アドレスまたは検索語" : "検索、URL、または「terminal」",
                                onMove: {model.move($0)}, onCommit: {model.commit(split: $0)}, onCancel: {model.onCancel()})
                    .frame(height: 24)
            }.padding(.horizontal, 16).frame(height: 52)
            if !model.items.isEmpty {
                Divider()
                ScrollViewReader {proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) {index, item in
                                row(item, selected: index == model.selection)
                                    .id(item.id)
                                    .onTapGesture {model.selection = index; model.commit(split: NSEvent.modifierFlags.contains(.option))}
                            }
                        }.padding(6)
                    }
                    .frame(height: min(340, CGFloat(model.items.count) * 36 + 10))
                    .onChange(of: model.selection) {_, value in
                        if model.items.indices.contains(value) {proxy.scrollTo(model.items[value].id)}
                    }
                }
                Divider()
                HStack(spacing: 14) {
                    Text("↑↓ 選択")
                    Text("⏎ 決定")
                    if !model.context.editing {Text("⌥⏎ 右に並べて開く")}
                    Spacer()
                    Text("esc 閉じる")
                }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 14).frame(height: 26)
            }
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
    }
    private func row(_ item: CommandBarItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if item.address != nil, ["globe", "clock", "pin"].contains(item.icon) {FaviconView(address: item.address, size: 16, fallback: item.icon)}
                else {Image(systemName: item.icon).font(.system(size: 13)).frame(width: 16, height: 16)}
            }.foregroundStyle(.secondary)
            Text(item.title).lineLimit(1).truncationMode(.middle)
            Text(item.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if selected {Text(item.hint + " ⏎").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()}
        }
        .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 34)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

/// An AppKit field: arrow keys move the selection instead of the caret, and the
/// current address arrives selected so typing replaces it.
struct CommandBarField: NSViewRepresentable {
    @Binding var text: String
    let focus: Int
    let placeholder: String
    let onMove: (Int) -> Void
    let onCommit: (_ split: Bool) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator {Coordinator(self)}
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 18); field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {field.stringValue = text}
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandBarField
        var focus = -1
        init(_ parent: CommandBarField) {self.parent = parent}
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField {parent.text = field.stringValue}
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Leave keys to the input method while it is composing Japanese text.
            if textView.hasMarkedText() {return false}
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onCommit(false); return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): parent.onCommit(true); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

private final class CommandBarWindow: NSPanel {
    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}
}

/// The command bar lives in its own child window so it always draws above
/// Chromium and terminal views, which are native layers inside the main window.
@MainActor final class CommandBarPanel: NSObject, NSWindowDelegate {
    static let shared = CommandBarPanel()
    private let model = CommandBarModel()
    private var panel: CommandBarWindow?
    private weak var parent: NSWindow?
    private weak var browserFocus: NCChromiumView?
    private var closing = false
    var isVisible: Bool {panel?.isVisible == true}

    func show(over window: NSWindow, context: CommandBarContext, commit: @escaping (CommandBarItem.Action, Bool) -> Void) {
        if !isVisible {browserFocus = NCChromiumOwnerForWindow(NSApp.keyWindow)}
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let parent, parent !== window {parent.removeChildWindow(panel)}
        parent = window
        model.onCommit = { [weak self] action, split in self?.close(); commit(action, split) }
        model.onCancel = { [weak self] in self?.close() }
        model.begin(context)
        let size = NSSize(width: 640, height: 440)
        let frame = window.frame
        // Anchored by its top edge, a third of the way down, so results grow downward.
        let top = frame.maxY - max(90, frame.height * 0.2)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
        if panel.parent == nil {window.addChildWindow(panel, ordered: .above)}
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let panel, panel.isVisible, !closing else {return}
        closing = true; defer {closing = false}
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let browserFocus, browserFocus.window === parent, !browserFocus.isHidden {browserFocus.focusContent()}
        else {parent?.makeKey()}
        browserFocus = nil
    }

    func windowDidResignKey(_ notification: Notification) {close()}

    private func makePanel() -> CommandBarWindow {
        let panel = CommandBarWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovable = false; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingView(rootView: VStack(spacing: 0) {CommandBarView(model: model); Spacer(minLength: 0)})
        panel.contentView = host
        return panel
    }
}
