import SwiftUI
import AppKit

/// Shared look of a sidebar row: a rounded highlight when selected or hovered.
struct SidebarRowStyle: ViewModifier {
    let selected: Bool
    /// Chosen but covered by something else on screen.
    var marked = false
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.11) : hovered ? Color.primary.opacity(0.055) : marked ? Color.primary.opacity(0.035) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .onHover {hovered = $0}
    }
}

/// Sidebar measurements shared by every section, so rows, labels and tiles line up.
enum SidebarMetrics {
    /// Outer gutter: where a row's highlight begins.
    static let gutter: CGFloat = 10
    /// Inner padding: where a row's icon or a section label begins, inside the highlight.
    static let inset: CGFloat = 10
    static let rowHeight: CGFloat = 32
    static let rowSpacing: CGFloat = 2
    static let sectionSpacing: CGFloat = 18
}

/// A section title with one quiet action at its right edge.
struct SidebarSectionHeader<Action: View>: View {
    let title: String
    @ViewBuilder var action: Action
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            action.foregroundStyle(.tertiary)
        }
        .padding(.leading, SidebarMetrics.gutter + SidebarMetrics.inset).padding(.trailing, SidebarMetrics.gutter + 2)
        .frame(height: 22)
    }
}

/// Shows secondary controls only while the pointer is over the row.
struct HoverReveal<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovered = false
    var body: some View {content(hovered).onHover {hovered = $0}}
}

/// One dot for a folded project: whether any of its worktrees has something running.
struct SidebarProjectActivity: View {
    @Environment(AppModel.self) private var model
    let projectId: String
    var body: some View {
        let ids = Set(model.state.workspaces.filter {$0.projectId == projectId}.map(\.id))
        WorkspaceActivityIndicator(terminals: model.state.terminals.filter {ids.contains($0.workspaceId)},
                                   connected: model.connected, showsStopped: false)
    }
}

/// Keeps every opened fixed tab alive in the main area and shows the selected one.
struct FixedTabPanes: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var store = FixedTabs.shared
    var body: some View {
        ForEach(store.tabs.filter {model.openedFixedIds.contains($0.id)}) {tab in
            let shown = model.fixedId == tab.id
            FixedTabView(tab: tab)
                .background(Palette.surface)
                .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
        }
    }
}

/// The fixed tabs of the sidebar: an icon row shown in every Space, then this Space's own rows.
struct SidebarFixedTabs: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var store = FixedTabs.shared
    @State private var renaming: FixedTab?
    @State private var name = ""
    @State private var stopping: FixedTab?

    var body: some View {
        let space = model.sidebarSpaces.active
        let global = store.global
        let local = store.tabs(in: space.id, spaces: model.sidebarSpaces.spaces)
        VStack(alignment: .leading, spacing: 6) {
            SidebarSectionHeader(title: "固定タブ") {
                Button {model.newFixedTabKind = FixedTabKind(id: "browser")} label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Webサイト・エージェント・Terminalをサイドバーに固定します。タブの右クリックからも固定できます")
                .accessibilityLabel("固定タブを追加")
            }
            if global.isEmpty && local.isEmpty {
                Text("よく使うサイトやエージェントをここに置けます")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, SidebarMetrics.gutter + SidebarMetrics.inset).padding(.bottom, 2)
            }
            if !global.isEmpty {
                // Four even columns, like a shelf: the same tabs in every Space.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(global) {tab in tile(tab)}
                }.padding(.horizontal, SidebarMetrics.gutter).padding(.bottom, local.isEmpty ? 0 : 4)
            }
            if !local.isEmpty {
                VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                    ForEach(local) {tab in row(tab)}
                }.padding(.horizontal, SidebarMetrics.gutter)
            }
        }
        .alert("固定タブの名前", isPresented: Binding(get: {renaming != nil}, set: {if !$0 {renaming = nil}})) {
            TextField("名前", text: $name)
            Button("キャンセル", role: .cancel) {renaming = nil}
            Button("変更") {
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tab = renaming, !value.isEmpty {store.update(tab.id) {$0.title = value}}
                renaming = nil
            }
        }
        .confirmationDialog("\(stopping?.title ?? "")のプロセスを停止しますか？", isPresented: Binding(get: {stopping != nil}, set: {if !$0 {stopping = nil}})) {
            Button("停止", role: .destructive) {
                if let terminal = model.terminal(id: stopping?.terminalId) {Task {await model.stopTerminal(terminal)}}
                stopping = nil
            }
        }
    }

    private func running(_ tab: FixedTab) -> Bool {model.terminal(id: tab.terminalId)?.status == "running"}

    @ViewBuilder private func icon(_ tab: FixedTab, size: CGFloat) -> some View {
        if tab.kind == "browser" {FaviconView(address: tab.url, size: size)}
        else {Image(systemName: tab.icon).font(.system(size: size * 0.82)).frame(width: size, height: size)}
    }

    private func tile(_ tab: FixedTab) -> some View {
        let selected = model.fixedId == tab.id
        return Button {model.openFixed(tab.id)} label: {
            icon(tab, size: 18)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {if running(tab) {Circle().fill(.green).frame(width: 5, height: 5).padding(4)}}
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title + (tab.url.map {"\n" + $0} ?? "")).accessibilityLabel("固定タブ: \(tab.title)")
        .contextMenu {menu(tab)}
        .draggable("fixed." + tab.id)
        .dropDestination(for: String.self) {ids, _ in drop(ids, before: tab)}
    }

    private func row(_ tab: FixedTab) -> some View {
        let selected = model.fixedId == tab.id
        return Button {model.openFixed(tab.id)} label: {
            HStack(spacing: 10) {
                icon(tab, size: 15).foregroundStyle(selected ? Color.accentColor : Color.secondary).frame(width: 16)
                Text(tab.title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if running(tab) {Circle().fill(.green).frame(width: 5, height: 5)}
                // Loaded in the background: can be put away to free it.
                else if tab.kind == "browser", model.openedFixedIds.contains(tab.id), !selected {Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4)}
            }
            .padding(.horizontal, SidebarMetrics.inset).frame(height: SidebarMetrics.rowHeight)
            .modifier(SidebarRowStyle(selected: selected))
        }
        .buttonStyle(.plain)
        .help(tab.url ?? tab.kindName).accessibilityLabel("固定タブ: \(tab.title)").accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {menu(tab)}
        .draggable("fixed." + tab.id)
        .dropDestination(for: String.self) {ids, _ in drop(ids, before: tab)}
    }

    private func drop(_ ids: [String], before tab: FixedTab) -> Bool {
        guard let id = ids.first, id.hasPrefix("fixed.") else {return false}
        store.move(String(id.dropFirst(6)), before: tab.id)
        return true
    }

    @ViewBuilder private func menu(_ tab: FixedTab) -> some View {
        Button("開く") {model.openFixed(tab.id)}
        if model.openedFixedIds.contains(tab.id), tab.kind == "browser" {
            Button("片付ける（ページを破棄して行き先に戻す）") {model.closeFixed(tab.id, unload: true)}
            Button("現在のページを行き先にする") {
                if let browser = BrowserModel.live("fixed.\(tab.id)"), let url = BrowserModel.navigationURL(browser.address), url.host != nil {
                    store.update(tab.id) {$0.url = url.absoluteString}
                }
            }
        }
        if running(tab) {Button("プロセスを停止…") {stopping = tab}}
        Divider()
        Button("名前を変更…") {name = tab.title; renaming = tab}
        if tab.spaceId == nil {
            Button("このSpaceだけに表示") {store.update(tab.id) {$0.spaceId = model.sidebarSpaces.active.id}}
        } else {
            Button("すべてのSpaceに表示（全体共通）") {store.update(tab.id) {$0.spaceId = nil}}
        }
        Divider()
        Button(tab.isTerminal && running(tab) ? "固定を解除（タブとして元の作業に戻す）" : "固定を解除", role: .destructive) {unfix(tab)}
    }

    /// Removing the row never stops a process: a running terminal returns to its worktree's tabs.
    private func unfix(_ tab: FixedTab) {
        let terminal = model.terminal(id: tab.terminalId)
        model.removeFixed(tab.id)
        if let terminal, terminal.status == "running", model.state.workspaces.contains(where: {$0.id == terminal.workspaceId}) {
            model.select(terminal.workspaceId)
            model.requestedTerminalId = terminal.id
        }
    }
}
