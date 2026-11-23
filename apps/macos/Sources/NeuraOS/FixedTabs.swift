import SwiftUI
import AppKit
import ChromiumBridge

/// A tab that stays in the sidebar: a web page, a terminal or an agent conversation.
/// Closing it only puts it away; the row remains until the user removes it.
struct FixedTab: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    /// "browser", "shell", "claude" or "codex".
    var kind: String
    var title: String
    /// Saved destination of a web page. Opening the tab after it was put away starts here.
    var url: String?
    /// The sidebar Space that shows this tab; nil shows it in every Space.
    var spaceId: String?
    /// Set for a tab that belongs to one project: it is listed under that project, whichever
    /// worktree is open, and `spaceId` is ignored.
    var projectId: String?
    /// Where a terminal or agent runs, chosen when the tab was fixed.
    var workspaceId: String?
    var terminalId: String?

    var isTerminal: Bool {["shell", "claude", "codex"].contains(kind)}
    var icon: String {kind == "codex" ? "sparkle" : kind == "claude" ? "asterisk" : kind == "shell" ? "terminal" : "globe"}
    var kindName: String {kind == "codex" ? "Codex" : kind == "claude" ? "Claude Code" : kind == "shell" ? "Terminal" : "Webサイト"}
}

@MainActor final class FixedTabs: ObservableObject {
    static let shared = FixedTabs()
    @Published private(set) var tabs: [FixedTab]
    private let defaults: UserDefaults
    private static let key = "fixedTabs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tabs = defaults.data(forKey: Self.key).flatMap {try? JSONDecoder().decode([FixedTab].self, from: $0)} ?? []
    }

    /// Tabs shown in every Space, as the icon row at the top of the sidebar.
    var global: [FixedTab] {tabs.filter {$0.spaceId == nil && $0.projectId == nil}}
    /// A project's own tabs, shown under its name in the sidebar.
    func tabs(inProject projectId: String) -> [FixedTab] {tabs.filter {$0.projectId == projectId}}
    /// A Space's own tabs. A tab whose Space no longer exists falls back to the first Space.
    func tabs(in spaceId: String, spaces: [SidebarSpace]) -> [FixedTab] {
        let known = Set(spaces.map(\.id)), fallback = spaces.first?.id
        return tabs.filter {tab in
            guard tab.projectId == nil, let owner = tab.spaceId else {return false}
            return owner == spaceId || (!known.contains(owner) && spaceId == fallback)
        }
    }
    func tab(_ id: String) -> FixedTab? {tabs.first {$0.id == id}}
    /// Terminals shown by a fixed tab are not listed again among their worktree's tabs.
    func owns(terminal id: String) -> Bool {tabs.contains {$0.terminalId == id}}
    func tab(owning terminalId: String) -> FixedTab? {tabs.first {$0.terminalId == terminalId}}
    func startingTabIds(in workspaceId: String) -> [String] {tabs.filter {$0.workspaceId == workspaceId}.map(\.id)}

    @discardableResult
    func add(_ tab: FixedTab) -> FixedTab {
        var tab = tab
        tab.title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.title.isEmpty {tab.title = tab.url.map(BrowserInput.displayHost) ?? tab.kindName}
        tabs.append(tab)
        save()
        return tab
    }

    func update(_ id: String, _ change: (inout FixedTab) -> Void) {
        guard let index = tabs.firstIndex(where: {$0.id == id}) else {return}
        var tab = tabs[index]
        change(&tab)
        guard tab != tabs[index] else {return}
        tabs[index] = tab
        save()
    }

    func remove(_ id: String) {
        guard tabs.contains(where: {$0.id == id}) else {return}
        tabs.removeAll {$0.id == id}
        save()
    }

    /// Reorder within the list the dragged tab already belongs to.
    func move(_ id: String, before targetId: String?) {
        guard id != targetId, let source = tabs.firstIndex(where: {$0.id == id}) else {return}
        if let targetId, let target = tabs.first(where: {$0.id == targetId}),
           target.spaceId != tabs[source].spaceId || target.projectId != tabs[source].projectId {return}
        let tab = tabs.remove(at: source)
        let destination = targetId.flatMap {target in tabs.firstIndex(where: {$0.id == target})} ?? tabs.endIndex
        tabs.insert(tab, at: destination)
        save()
    }

    func terminalBinding(_ id: String) -> Binding<String?> {
        Binding(get: { [weak self] in self?.tab(id)?.terminalId },
                set: { [weak self] value in self?.update(id) {$0.terminalId = value} })
    }

    /// Fix a page to a project. The same address is fixed once per project.
    @discardableResult
    func fix(url: String, title: String, toProject projectId: String) -> (tab: FixedTab, added: Bool) {
        if let existing = tabs.first(where: {$0.projectId == projectId && $0.kind == "browser" && $0.url == url}) {return (existing, false)}
        return (add(FixedTab(kind: "browser", title: title, url: url, projectId: projectId)), true)
    }

    /// Pages pinned to a project by earlier versions (icons in the worktree tab strip) become
    /// that project's fixed tabs. Each project's saved list is converted once, then removed.
    func adoptPins(projectIds: [String]) {
        struct Pin: Codable {var id: String; var url: String; var title: String}
        var changed = false
        for projectId in projectIds {
            let key = "browserPins.\(projectId)"
            guard let data = defaults.data(forKey: key) else {continue}
            for pin in (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
            where !tabs.contains(where: {$0.projectId == projectId && $0.url == pin.url}) {
                tabs.append(FixedTab(kind: "browser", title: pin.title.isEmpty ? BrowserInput.displayHost(pin.url) : pin.title,
                                     url: pin.url, projectId: projectId))
                changed = true
            }
            defaults.removeObject(forKey: key)
        }
        if changed {save()}
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tabs) {defaults.set(data, forKey: Self.key)}
    }
}

extension AppModel {
    /// Show a fixed tab in the main area. The selected worktree stays selected underneath.
    func openFixed(_ id: String) {
        guard let tab = FixedTabs.shared.tab(id) else {return}
        Diagnostics.shared.record("action.open-fixed-tab")
        // A project's tab sits over one of that project's worktrees, so links it opens land there.
        if let projectId = tab.projectId, selected?.projectId != projectId, let host = hostWorkspace(for: projectId) {select(host.id)}
        if !openedFixedIds.contains(id), tab.kind == "browser", let url = tab.url {
            // A page that was put away starts again from its saved destination.
            UserDefaults.standard.set(url, forKey: "browser.fixed.\(id)")
        }
        openedFixedIds.insert(id)
        fixedId = id
    }

    /// Put a fixed tab away. A web page is unloaded; a terminal or agent keeps running.
    func closeFixed(_ id: String, unload: Bool) {
        if unload {openedFixedIds.remove(id)}
        if fixedId == id {
            fixedId = nil
            // With no worktree underneath, nothing is left to take tab commands.
            if selected == nil {activeTabKind = nil}
        }
    }

    func removeFixed(_ id: String) {
        closeFixed(id, unload: true)
        FixedTabs.shared.remove(id)
    }

    /// The workspace a new terminal or agent tab would run in for a project.
    func hostWorkspace(for projectId: String) -> Workspace? {
        let candidates = state.workspaces.filter {$0.projectId == projectId}
        return candidates.first {$0.kind != "worktree"} ?? candidates.first
    }
}

/// The main-area surface of one fixed tab.
struct FixedTabView: View {
    @Environment(AppModel.self) private var model
    @ObservedObject private var store = FixedTabs.shared
    let tab: FixedTab
    @State private var pageTitle: String?
    @State private var pageURL: String?
    // Pages opened by this one (sign-in windows, target=_blank) stack on top and can be dismissed.
    @State private var popups: [Popup] = []
    @State private var showStop = false
    struct Popup: Identifiable {let id = UUID().uuidString.lowercased(); let view: NCChromiumView; let url: String}

    private var shown: Bool {model.fixedId == tab.id}
    private var storageId: String {"fixed.\(tab.id)"}
    private var workspace: Workspace? {model.state.workspaces.first {$0.id == tab.workspaceId}}

    var body: some View {
        VStack(spacing: 0) {
            if !popups.isEmpty {popupBar}
            ZStack {
                content
                ForEach(popups) {popup in
                    let top = popup.id == popups.last?.id
                    BrowserPane(storageId: "fixed.\(popup.id)", workspaceId: "fixed", projectId: "", visible: shown && top,
                                title: .constant(nil), url: .constant(nil), fixed: true, automation: false, view: popup.view,
                                actions: actions(popup: popup.id))
                        .background(Palette.surface)
                        .opacity(top ? 1 : 0).allowsHitTesting(shown && top)
                }
            }
        }
        .onReceive(model.workspaceCommands) {request in
            guard request.workspaceId == "fixed.\(tab.id)", shown else {return}
            handle(request.action)
        }
        .onChange(of: shown) {_, _ in publishKind()}
        .onAppear {publishKind()}
        .confirmationDialog("\(tab.title)のプロセスを停止しますか？", isPresented: $showStop) {
            Button("停止", role: .destructive) {
                if let terminal = model.terminal(id: tab.terminalId) {Task {await model.stopTerminal(terminal)}}
            }
        }
    }

    /// Shown only while a page opened by this tab (a sign-in window, a new-window link) is on top.
    private var popupBar: some View {
        HStack(spacing: 8) {
            Button {dismissPopup()} label: {Label("\(tab.title)に戻る", systemImage: "chevron.left")}.buttonStyle(.plain)
            Spacer()
            Text("このタブから開いたページ").foregroundStyle(.tertiary)
        }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 26).background(Color.primary.opacity(0.035))
    }

    @ViewBuilder private var content: some View {
        if tab.kind == "browser" {
            BrowserPane(storageId: storageId, workspaceId: "fixed", projectId: "", visible: shown && popups.isEmpty,
                        title: $pageTitle, url: $pageURL, fixed: true, automation: false, actions: actions(popup: nil))
        } else if let workspace {
            TerminalPane(workspace: workspace, tabId: tab.id, provider: tab.kind, terminalId: store.terminalBinding(tab.id),
                         visible: shown, active: shown, onOpenURL: {url in openInWorktree(url)})
        } else {
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.secondary)
                Text("この固定タブの作業フォルダが見つかりません").font(.system(size: 15, weight: .medium))
                Text("プロジェクトやworktreeが削除された可能性があります。").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("固定を解除") {model.removeFixed(tab.id)}.disabled(model.isTerminalStarting(tab.id))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func actions(popup: String?) -> BrowserPaneActions {
        BrowserPaneActions(
            popup: {view, url in popups.append(Popup(view: view, url: url)); return true},
            openTab: {address, _ in if let url = BrowserModel.navigationURL(address) {openInWorktree(url)}},
            closed: {if let popup {popups.removeAll {$0.id == popup}}},
            editAddress: {_ in showCommandBar(edit: true)},
            togglePin: {address, title in
                // The pin button of a fixed page saves where it is now as its destination.
                guard popup == nil, let url = BrowserModel.navigationURL(address), url.host != nil else {return}
                store.update(tab.id) {$0.url = url.absoluteString; if !title.isEmpty {$0.title = title}}
                frontBrowser()?.flash("この場所を固定タブの行き先にしました")
            },
            toggleSplit: {}
        )
    }

    private func frontBrowser() -> BrowserModel? {
        if let popup = popups.last {return BrowserModel.live("fixed.\(popup.id)")}
        return tab.kind == "browser" ? BrowserModel.live(storageId) : nil
    }

    private func dismissPopup() {
        guard let popup = popups.popLast() else {return}
        popup.view.close()
    }

    private func publishKind() {
        guard shown else {return}
        let kind = popups.isEmpty ? tab.kind : "browser"
        if model.activeTabKind != kind {model.activeTabKind = kind}
    }

    /// Links and new pages leave the fixed tab and open among the selected worktree's tabs.
    private func openInWorktree(_ url: URL) {
        guard let workspaceId = model.selectedId else {
            frontBrowser()?.navigate(url.absoluteString)
            return
        }
        forward(.open(url, .tab), to: workspaceId)
    }

    private func forward(_ action: WorkspaceAction, to workspaceId: String) {
        model.fixedId = nil
        model.workspaceCommands.send(WorkspaceCommandRequest(workspaceId: workspaceId, action: action))
    }

    private func handle(_ action: WorkspaceAction) {
        switch action {
        case .close:
            if !popups.isEmpty {dismissPopup()}
            // Putting a page away unloads it; a terminal or agent keeps running in the background.
            else {model.closeFixed(tab.id, unload: tab.kind == "browser")}
        case .browser(let command):
            guard command != .togglePin else {
                if let browser = frontBrowser() {actions(popup: nil).togglePin(browser.address, browser.title)}
                return
            }
            frontBrowser()?.perform(command)
        case .navigate(let url):
            if let browser = frontBrowser() {browser.navigate(url.absoluteString); browser.view.focusContent()}
        case .commandBar(let edit): showCommandBar(edit: edit)
        case .recent, .finishRecent, .toggleSplit: break
        default:
            // Tab commands belong to the worktree underneath.
            if let workspaceId = model.selectedId {forward(action, to: workspaceId)}
        }
    }

    private func showCommandBar(edit: Bool) {
        guard let window = NSApp.windows.first(where: {$0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible}) ?? NSApp.mainWindow else {return}
        let browser = frontBrowser()
        let selected = model.selected
        let context = CommandBarContext(editing: edit && browser != nil, currentURL: browser?.address ?? "",
                                        workspaceId: selected?.id ?? "",
                                        conversationProvider: selected.map {model.conversationProvider(for: $0)} ?? "codex",
                                        canLaunch: selected != nil,
                                        tabs: model.browserTabs(),
                                        fixed: store.tabs, workspaces: model.commandBarWorkspaces())
        CommandBarPanel.shared.show(over: window, context: context) {action, _ in
            switch action {
            case .navigate(let url): handle(.navigate(url))
            case .open(let url): openInWorktree(url)
            case .focusTab(let workspaceId, let tabId): model.requestedTab = (workspaceId, tabId); model.select(workspaceId)
            case .add(let kind): if let workspaceId = model.selectedId {forward(.add(kind), to: workspaceId)}
            case .openFixed(let id): model.openFixed(id)
            case .focusWorkspace(let id): model.select(id)
            }
        }
    }
}

/// Creates a fixed tab: what it shows, where it runs, and which Spaces show it.
struct NewFixedTabSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var kind: String
    var project: String?
    @State private var title = ""
    @State private var address = ""
    @State private var projectId = ""
    /// "space", "all" or "project".
    @State var scope = "space"

    private var projects: [Project] {model.state.projects.filter {model.hostWorkspace(for: $0.id) != nil}}
    private var url: URL? {BrowserInput.address(address)}
    private var valid: Bool {
        if kind != "browser" {return model.hostWorkspace(for: projectId) != nil}
        return url?.host != nil && (scope != "project" || model.state.projects.contains {$0.id == projectId})
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("固定タブを追加").font(.title2.bold())
            Text("サイドバーに常に置いておくタブです。閉じても消えず、次に開くと同じ場所から始まります。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("種類", selection: $kind) {
                Text("Webサイト").tag("browser")
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
                Text("Terminal").tag("shell")
            }.pickerStyle(.segmented).labelsHidden()
            if kind == "browser" {
                TextField("アドレス（例：linear.app、localhost:3000）", text: $address).textFieldStyle(.roundedBorder)
            } else {
                Picker("作業フォルダ", selection: $projectId) {
                    ForEach(projects) {project in
                        Text(project.folderless == true ? "\(project.name)（フォルダなし）" : project.name).tag(project.id)
                    }
                }
                Text("このタブのTerminal／エージェントは、選んだプロジェクトの元フォルダで動きます。どのworktreeを開いていても同じタブです。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField(kind == "browser" ? "名前（空欄ならサイト名）" : "名前（例：調べもの係）", text: $title).textFieldStyle(.roundedBorder)
            Picker("表示する場所", selection: $scope) {
                Text("このWorkspace（\(model.sidebarSpaces.active.name)）").tag("space")
                Text("すべてのWorkspace（全体共通）").tag("all")
                Text("プロジェクトの下（そのプロジェクト専用）").tag("project")
            }.pickerStyle(.radioGroup)
            if scope == "project", kind == "browser" {
                Picker("プロジェクト", selection: $projectId) {
                    ForEach(model.state.projects) {project in Text(project.name).tag(project.id)}
                }
            }
            HStack {
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("追加") {
                    var tab = FixedTab(kind: kind, title: title, spaceId: scope == "space" ? model.sidebarSpaces.active.id : nil,
                                       projectId: scope == "project" ? projectId : nil)
                    if kind == "browser" {tab.url = url?.absoluteString} else {tab.workspaceId = model.hostWorkspace(for: projectId)?.id}
                    let added = FixedTabs.shared.add(tab)
                    dismiss()
                    model.openFixed(added.id)
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear {
            if let project {projectId = project; scope = "project"}
            if projectId.isEmpty {projectId = model.selected?.projectId ?? projects.first?.id ?? ""}
        }
    }
}
