import SwiftUI
import AppKit
import ChromiumBridge

struct WorkspaceTab: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var kind: String
    var number = 1
    var terminalId: String?
    var browserTitle: String?
    var filePath: String?
    var title: String {
        if kind == "file", let filePath {return (filePath as NSString).lastPathComponent}
        if kind == "browser", let browserTitle, !browserTitle.isEmpty {return browserTitle}
        let name = kind == "agents" ? "作業一覧" : kind == "codex" ? "Codex" : kind == "claude" ? "Claude Code" : kind == "shell" ? "Terminal" : kind == "browser" ? "Browser" : kind == "files" ? "ファイル" : kind == "github" ? "GitHub" : "差分"
        return ["files", "diff", "github", "agents"].contains(kind) ? name : "\(name) \(number)"
    }
    func displayTitle(terminal: TerminalRecord?) -> String {
        if ["codex", "claude"].contains(kind), terminal?.id == terminalId,
           let name = terminal?.sessionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {return name}
        return title
    }
    var icon: String {kind == "agents" ? "person.3" : kind == "codex" ? "sparkle" : kind == "claude" ? "asterisk" : kind == "shell" ? "terminal" : kind == "browser" ? "globe" : ["file", "files"].contains(kind) ? "doc" : kind == "github" ? "arrow.triangle.pull" : "plus.forwardslash.minus"}
    var isTerminal: Bool {["codex", "claude", "shell"].contains(kind)}
}
struct WorkspaceTabState: Codable {
    var tabs: [WorkspaceTab] = []
    var selectedId: String?

    mutating func openFile(_ path: String) {
        if let existing = tabs.first(where: {$0.kind == "file" && $0.filePath == path}) {
            selectedId = existing.id
        } else {
            let tab = WorkspaceTab(kind: "file", filePath: path)
            tabs.append(tab); selectedId = tab.id
        }
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
        if !tabs.contains(where: {$0.id == selectedId}) {selectedId = tabs.first?.id}
    }
}

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    @State private var layout = WorkspaceTabState()
    @State private var restored = false
    @State private var seenTerminalIds: Set<String> = []
    @State private var git = GitStatus()
    @State private var selectedDiff: Diff?
    @State private var gitError: String?
    @State private var inspector = "files"
    @State private var treeVersion = 0
    @State private var documents: [String: OpenDocument] = [:]
    private var selectedFile: String? {layout.tabs.first {$0.id == layout.selectedId}?.filePath}
    @State private var closingTab: WorkspaceTab?
    @State private var popupViews: [String: NCChromiumView] = [:]
    private var activeKind: String? {layout.tabs.first {$0.id == layout.selectedId}?.kind}
    private var storageKey: String {"workspaceTabs.\(workspace.id)"}
    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Palette.line).frame(height: 1)
            HSplitView {
                contents.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector && workspace.hasFolder {inspectorPane.frame(minWidth: 240, idealWidth: 260, maxWidth: 400)}
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 10) {
                if workspace.supportsGit {
                    Label(git.branch.isEmpty ? workspace.branch : git.branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                        .help(git.branch.isEmpty ? workspace.branch : git.branch)
                }
                if workspace.hasFolder {
                    Text((workspace.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).help(workspace.path)
                } else {
                    Text("フリー")
                    if let project = model.state.projects.first(where: {$0.id == workspace.projectId}), project.folderless == true {
                        Button("フォルダを紐づける…") {model.attachFolder(to: project)}
                            .buttonStyle(.link).disabled(model.isBusy("project.attach.\(project.id)") || !model.connected || !model.supportsFolderless)
                    }
                }
                Spacer(minLength: 0)
                if model.isBusy(workspace.id) {ProgressView().controlSize(.mini)}
                if workspace.supportsGit && !git.changes.isEmpty {
                    Text("\(git.changes.count)件の変更").fixedSize()
                }
                Rectangle().fill(Palette.line).frame(width: 1, height: 12)
                ProviderUsageFooter()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }
        .onAppear {restore(); openRequestedTerminal()}
        .onChange(of: model.state.terminalMembership) {_, _ in reconcileTerminals()}
        .onReceive(model.terminalLaunchesChanged) {_ in
            // Keep launch lifecycle events even when several changes share a render turn.
            Task { @MainActor in reconcileTerminals() }
        }
        .onChange(of: model.requestedTerminalId) {_, _ in openRequestedTerminal()}
        .onReceive(model.workspaceUpdated) {id in
            if id == workspace.id {treeVersion += 1; selectedDiff = nil}
        }
        .onReceive(model.workspaceCommands) {request in
            guard request.workspaceId == workspace.id, model.selectedId == workspace.id,
                  closingTab == nil else {return}
            switch request.action {
            case .add(let kind): add(kind)
            case .close:
                if let item = layout.tabs.first(where: {$0.id == layout.selectedId}) {close(item)}
            case .move(let offset): layout.moveSelection(by: offset)
            case .select(let number): layout.select(number: number)
            case .inspector(let pane): inspector = pane; model.showInspector = true
            }
        }
        .onChange(of: inspector) {_, value in UserDefaults.standard.set(value, forKey: "inspector.\(workspace.id)")}
        .onChange(of: documents) {_, value in DraftCache.shared.update(workspace.id, value)}
        .onChange(of: layout.tabs) {_, _ in persist()}
        .onChange(of: layout.selectedId) {_, _ in Diagnostics.shared.record("action.select-tab"); persist()}
        .confirmationDialog("タブを閉じてプロセスを停止しますか？", isPresented: Binding(get: {closingTab != nil}, set: {if !$0 {closingTab = nil}})) {
            if let item = closingTab {
                Button("停止して閉じる", role: .destructive) {
                    Task {
                        if let terminal = model.terminal(id: item.terminalId), !(await model.stopTerminal(terminal)) {return}
                        remove(item)
                    }
                }
                Button("キャンセル", role: .cancel) {closingTab = nil}
            }
        } message: {Text("このタブで実行中のCLIやコマンドを終了します。")}
        .task(id: workspace.supportsGit) {
            while !Task.isCancelled {if model.selectedId == workspace.id {await refreshGit()}; try? await Task.sleep(for: .seconds(3))}
        }
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollViewReader {proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(layout.tabs) {item in
                            let title = item.displayTitle(terminal: model.terminal(id: item.terminalId))
                            HStack(spacing: 8) {
                                Button {layout.selectedId = item.id} label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: item.icon)
                                        Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
                                        if let path = item.filePath, documents[path]?.dirty == true {Circle().frame(width: 5, height: 5)}
                                        TerminalRunningIndicator(terminalId: item.terminalId)
                                    }.padding(.leading, 10).frame(height: 31).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel(title).help(item.filePath ?? title)
                                Button {close(item)} label: {Image(systemName: "xmark").font(.system(size: 9)).frame(width: 22, height: 28).contentShape(Rectangle())}.buttonStyle(.plain).disabled(model.isTerminalStarting(item.id)).accessibilityLabel("\(title)を閉じる").help("\(title)を閉じる" + (layout.selectedId == item.id ? "（⇧⌘W）" : ""))
                            }
                            .font(.system(size: 12)).foregroundStyle(layout.selectedId == item.id ? .primary : .secondary)
                            .background(layout.selectedId == item.id ? Color.primary.opacity(0.055) : .clear)
                            .overlay(alignment: .bottom) {if layout.selectedId == item.id {Rectangle().fill(Color.accentColor).frame(height: 2)}}
                            .id(item.id)
                        }
                    }
                }.scrollIndicators(.hidden)
                .onChange(of: layout.selectedId) {_, id in if let id {proxy.scrollTo(id)}}
            }
            Menu {addTabButtons} label: {Image(systemName: "plus").frame(width: 28, height: 32)}
                .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8).help("タブを追加（Terminal: ⌘T）。その他のキーは「タブ」メニュー")
        }.frame(height: 32)
    }
    @ViewBuilder private var addTabButtons: some View {
        Button {add("codex")} label: {Label("Codex", systemImage: "sparkle")}
        Button {add("claude")} label: {Label("Claude Code", systemImage: "asterisk")}
        Button {add("shell")} label: {Label("Terminal", systemImage: "terminal")}
        if model.state.features?.contains("agent.supervision") == true {Button {showUtility("agents")} label: {Label("Codexの作業一覧", systemImage: "person.3")}}
        Button {add("browser")} label: {Label("Browser", systemImage: "globe")}

    }
    private var contents: some View {
        ZStack {
            if layout.tabs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "plus.square.on.square").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text("タブを追加して作業を始める").font(.system(size: 18, weight: .medium))
                    HStack(spacing: 12) {addTabButtons}.controlSize(.large)
                    Text("同じ種類のタブも、複数開けます。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach($layout.tabs) {$item in
                let active = layout.selectedId == item.id
                let visible = active && model.selectedId == workspace.id
                Group {
                    if item.isTerminal {TerminalPane(workspace: workspace, tabId: item.id, provider: item.kind, terminalId: $item.terminalId, visible: visible)}
                    else if item.kind == "agents" {AgentSupervisor(workspace: workspace, visible: visible)}
                    else if item.kind == "file", let path = item.filePath {
                        FilePane(workspace: workspace, path: path, visible: visible, openFile: {layout.openFile($0)}, documents: $documents).id(path)
                    }
                    else if item.kind == "browser" {BrowserPane(storageId: "\(workspace.id).\(item.id)", workspaceId: workspace.id, visible: visible, title: $item.browserTitle, view: popupViews[item.id], onPopup: openBrowserPopup, onClosed: {remove(item)})}

                }.opacity(active ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
            }
            if activeKind == "diff" {
                if let diff = selectedDiff {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(diff.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(diff.path).padding(.horizontal, 8).frame(height: 28)
                        Divider()
                        NativeTextEditor(text: .constant(diff.content), editable: false, diff: true)
                    }
                } else {Text("右のGit一覧から差分を選択").foregroundStyle(.secondary)}
            }
        }
    }
    private var inspectorPane: some View {
        VStack(spacing: 0) {
            Picker("右サイドバー", selection: $inspector) {
                Text("エクスプローラー").tag("files")
                Text("Git").tag("git")
                Text("GitHub").tag("github")
            }.pickerStyle(.segmented).labelsHidden().padding(6)
            Divider()
            if inspector == "files" {
                HStack {
                    Text((workspace.path as NSString).lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button {treeVersion += 1} label: {Image(systemName: "arrow.clockwise")}.buttonStyle(.plain).help("ファイル一覧を更新")
                }.padding(.horizontal, 8).frame(height: 28)
                .modifier(ExplorerActions(workspaceId: workspace.id, path: "", directory: true, dirtyPaths: dirtyFilePaths, onChange: applyFileChange))
                Text("右クリックで作成・移動・ファイル操作").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                ScrollView {FileTree(workspaceId: workspace.id, path: "", selected: selectedFile, refreshVersion: treeVersion, dirtyPaths: dirtyFilePaths, onChange: applyFileChange, onSelect: {path in layout.openFile(path)}).padding(.horizontal, 10)}
            } else if inspector == "github" {
                GitHubSidebar(workspace: workspace, visible: model.showInspector && model.selectedId == workspace.id, openTerminal: {add("shell")})
            } else if workspace.supportsGit {gitPane}
            else {Text("このフォルダではGitを使用していません。").font(.system(size: 12)).foregroundStyle(.secondary).padding(18); Spacer()}
        }
    }
    private var dirtyFilePaths: Set<String> {Set(documents.filter {$0.value.dirty}.keys)}
    private func applyFileChange(_ change: ExplorerChange) {
        guard change.oldPath != nil else {return}
        for tab in layout.tabs {
            guard let path = tab.filePath else {continue}
            let mapped = ExplorerFiles.remap(path, change: change)
            if mapped != path {
                // Edits can arrive while a background filesystem operation is completing.
                if mapped == nil, documents[path]?.dirty == true {continue}
                if let mapped, let index = layout.tabs.firstIndex(where: {$0.id == tab.id}) {layout.tabs[index].filePath = mapped}
                else {layout.tabs.removeAll {$0.id == tab.id}}
            }
        }
        var updated: [String: OpenDocument] = [:]
        for (path, var document) in documents {
            if let mapped = ExplorerFiles.remap(path, change: change) {
                document.original = FileContent(path: mapped, content: document.original.content, hash: document.original.hash)
                updated[mapped] = document
            } else if document.dirty {updated[path] = document}
        }
        documents = updated
        if !layout.tabs.contains(where: {$0.id == layout.selectedId}) {layout.selectedId = layout.tabs.first?.id}
        persist()
    }
    private var gitPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(git.branch.isEmpty ? workspace.branch : git.branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                Spacer()
                Button {Task {await refreshGit()}} label: {Image(systemName: "arrow.clockwise")}.buttonStyle(.plain).help("差分を更新")
            }.font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
            HStack {Text("変更"); Text("\(git.changes.count)").foregroundStyle(.secondary); Spacer()}.font(.system(size: 11, weight: .medium)).padding(.horizontal, 14).padding(.bottom, 8)
            if let gitError {Text(gitError).font(.system(size: 11)).foregroundStyle(.secondary).padding(14)}
            if git.changes.isEmpty && gitError == nil {Label("変更はありません", systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.tertiary).padding(14)}
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(git.changes) {change in
                        Button {Task {do {selectedDiff = try await model.api.get("v1/workspaces/\(workspace.id)/diff", query: ["path": change.path]); showUtility("diff")} catch {model.report(error)}}} label: {
                            HStack(spacing: 8) {
                                Text(change.status.trimmingCharacters(in: .whitespaces)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(change.status == "??" ? .green : .orange).frame(width: 20)
                                Text(change.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(change.path)
                    }
                }
            }
        }
    }
    private func openBrowserPopup(_ view: NCChromiumView, url: String) -> Bool {
        let item = WorkspaceTab(kind: "browser", number: (layout.tabs.filter {$0.kind == "browser"}.map(\.number).max() ?? 0) + 1)
        popupViews[item.id] = view
        UserDefaults.standard.set(url, forKey: "browser.\(workspace.id).\(item.id)")
        layout.tabs.append(item); layout.selectedId = item.id
        return true
    }
    private func add(_ kind: String) {
        Diagnostics.shared.record("action.add-tab")
        let item = WorkspaceTab(kind: kind, number: (layout.tabs.filter {$0.kind == kind}.map(\.number).max() ?? 0) + 1)
        layout.tabs.append(item); layout.selectedId = item.id
    }
    private func showUtility(_ kind: String) {
        if let item = layout.tabs.first(where: {$0.kind == kind}) {layout.selectedId = item.id} else {add(kind)}
    }
    private func close(_ item: WorkspaceTab) {
        guard !model.isTerminalStarting(item.id) else {return}
        Diagnostics.shared.record("action.close-tab")
        if model.terminal(id: item.terminalId)?.status == "running" {closingTab = item} else {remove(item)}
    }
    private func remove(_ item: WorkspaceTab) {
        popupViews.removeValue(forKey: item.id)
        guard let index = layout.tabs.firstIndex(where: {$0.id == item.id}) else {return}
        layout.tabs.remove(at: index)
        if layout.selectedId == item.id {layout.selectedId = layout.tabs.isEmpty ? nil : layout.tabs[min(index, layout.tabs.count - 1)].id}
    }
    private func openRequestedTerminal() {
        guard let id = model.requestedTerminalId,
              let terminal = model.terminal(id: id), terminal.workspaceId == workspace.id else {return}
        restore()
        if let tab = layout.tabs.first(where: {$0.terminalId == id}) {layout.selectedId = tab.id}
        else {
            let tab = WorkspaceTab(kind: terminal.provider, number: (layout.tabs.filter {$0.kind == terminal.provider}.map(\.number).max() ?? 0) + 1, terminalId: id)
            layout.tabs.append(tab); layout.selectedId = tab.id
        }
        model.requestedTerminalId = nil
        persist()
    }
    private func restore() {
        guard !restored else {return}; restored = true
        let saved = UserDefaults.standard.data(forKey: storageKey).flatMap {try? JSONDecoder().decode(WorkspaceTabState.self, from: $0)}
        layout = saved ?? WorkspaceTabState()
        inspector = UserDefaults.standard.string(forKey: "inspector.\(workspace.id)") ?? "files"
        if layout.tabs.contains(where: {$0.kind == "github" && $0.id == layout.selectedId}) {
            inspector = "github"; model.showInspector = true
        }
        documents = DraftCache.shared.load(workspace.id)
        let wasFiles = layout.tabs.first {$0.id == layout.selectedId}?.kind == "files"
        layout.tabs.removeAll {$0.kind == "github" || $0.kind == "files"}
        let previousSelection = layout.selectedId
        for path in documents.keys.sorted() where documents[path]?.dirty == true {layout.openFile(path)}
        if !wasFiles, layout.tabs.contains(where: {$0.id == previousSelection}) {layout.selectedId = previousSelection}
        // Recover running sessions, including sessions opened while this UI was disconnected.
        let terminals = model.state.terminals.filter {$0.workspaceId == workspace.id}
        seenTerminalIds = Set(terminals.map(\.id))
        for terminal in terminals.filter({terminal in terminal.status == "running" || (saved == nil && terminals.last(where: {$0.provider == terminal.provider})?.id == terminal.id)}) {
            if !layout.tabs.contains(where: {$0.terminalId == terminal.id}) {
                let number = (layout.tabs.filter {$0.kind == terminal.provider}.map(\.number).max() ?? 0) + 1
                layout.tabs.append(WorkspaceTab(kind: terminal.provider, number: number, terminalId: terminal.id))
            }
        }
        if !layout.tabs.contains(where: {$0.id == layout.selectedId}) {layout.selectedId = layout.tabs.first?.id}
        persist()
    }
    private func reconcileTerminals() {
        guard restored else {return}
        layout.reconcileTerminals(model.state.terminals.filter {$0.workspaceId == workspace.id},
                                  seen: &seenTerminalIds, startingTabs: model.startingTerminalTabs)
    }
    private func persist() {guard restored, let data = try? JSONEncoder().encode(layout) else {return}; UserDefaults.standard.set(data, forKey: storageKey)}
    private func refreshGit() async {
        guard workspace.supportsGit else {return}
        do {
            let next: GitStatus = try await model.api.get("v1/workspaces/\(workspace.id)/git")
            if git != next {git = next}
            if gitError != nil {gitError = nil}
        } catch {
            if gitError != error.localizedDescription {gitError = error.localizedDescription}
        }
    }
}

// Observe activity-bearing records only at the leaf, never in the tab bar owner.
private struct TerminalRunningIndicator: View {
    @Environment(AppModel.self) private var model
    let terminalId: String?
    var body: some View {
        if model.terminal(id: terminalId)?.status == "running" {
            Circle().fill(.green).frame(width: 5, height: 5)
        }
    }
}

struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let tabId: String
    let provider: String
    @Binding var terminalId: String?
    let visible: Bool
    @State private var showStop = false
    @State private var hasBeenVisible = false
    @State private var attemptedAutoStart = false
    private var title: String {provider == "codex" ? "Codex" : provider == "claude" ? "Claude Code" : "Terminal"}
    var body: some View {
        let terminal = model.terminal(id: terminalId)
        VStack(spacing: 0) {
            if let terminal {
                HStack(spacing: 8) {
                    Circle().fill(terminal.status == "running" ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(terminal.status == "running" ? "実行中" : terminal.status == "interrupted" ? "Daemonの再起動により中断" : "終了").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if terminal.status == "running" {Button("停止") {showStop = true}.font(.system(size: 11)).buttonStyle(.plain)}
                    else {
                        if provider != "shell" {Button("履歴から再開") {launch(resume: true)}.font(.system(size: 11)).disabled(model.isBusy(workspace.id) || !model.connected)}
                        Button("新しく起動") {launch()}.font(.system(size: 11)).disabled(model.isBusy(workspace.id) || !model.connected)
                    }
                }.padding(.horizontal, 8).frame(height: 24)
                if visible || hasBeenVisible {NativeTerminal(terminal: terminal, api: model.api, visible: visible, onError: {model.report($0)}).padding(.horizontal, 4).frame(maxWidth: .infinity, maxHeight: .infinity).id(terminal.id)}
                else {Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)}
            } else {
                VStack(spacing: 16) {
                    Image(systemName: provider == "shell" ? "terminal" : "sparkle").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text("\(title)で作業する").font(.system(size: 19, weight: .medium))
                    Text(provider == "shell" ? "この作業フォルダでシェルを開きます。" : "ログイン済みのCLIを、そのまま使えます。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("\(title)を起動") {launch()}.controlSize(.large).disabled(model.isBusy(workspace.id) || !model.connected)
                    if provider != "shell" {Button("以前の会話から再開") {launch(resume: true)}.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isBusy(workspace.id) || !model.connected)}
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {activateIfNeeded()}
        .onChange(of: visible) {_, _ in activateIfNeeded()}
        .onChange(of: model.connected) {_, _ in activateIfNeeded()}
        .onReceive(model.pendingActionsChanged) {_ in
            // Preserve every release event so auto-start remains eligible after contention.
            Task { @MainActor in activateIfNeeded() }
        }
        .confirmationDialog("\(title)のプロセスを停止しますか？", isPresented: $showStop) {Button("停止", role: .destructive) {if let terminal {Task {await model.stopTerminal(terminal)}}}}
    }
    private func activateIfNeeded() {
        guard visible else {return}
        hasBeenVisible = true
        guard model.connected, !attemptedAutoStart, !model.isBusy(workspace.id) else {return}
        guard terminalId == nil else {attemptedAutoStart = true; return}
        launch()
    }
    private func launch(resume: Bool = false) {
        // Mark synchronously, before scheduling the task: both button and shortcut closes
        // must keep this tab mounted until its terminal binding has been updated.
        guard !model.isBusy(workspace.id), model.beginTerminalLaunch(tabId) else {return}
        Task {
            defer {model.endTerminalLaunch(tabId)}
            // Another tab may acquire the workspace after this task was queued.
            // Contention is not a real attempt; keep automatic retry eligible.
            guard !model.isBusy(workspace.id) else {return}
            attemptedAutoStart = true
            if let terminal = await model.openTerminal(workspace, provider: provider, resume: resume) {terminalId = terminal.id}
        }
    }
}

struct FileTree: View {
    @Environment(AppModel.self) private var model
    let workspaceId: String; let path: String; let selected: String?; let refreshVersion: Int; let dirtyPaths: Set<String>; let onChange: (ExplorerChange) -> Void; let onSelect: (String) -> Void
    @State private var entries: [FileEntry] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error {Text(error).font(.system(size: 10)).foregroundStyle(.secondary)}
            ForEach(entries) {entry in
                if entry.isDirectory {FolderRow(workspaceId: workspaceId, entry: entry, selected: selected, refreshVersion: refreshVersion, dirtyPaths: dirtyPaths, onChange: onChange, onSelect: onSelect)}
                else {Button {onSelect(entry.path)} label: {HStack(spacing: 7) {Image(systemName: "doc").foregroundStyle(.tertiary); Text(entry.name).lineLimit(1); Spacer(minLength: 0)}.font(.system(size: 11)).padding(.vertical, 6).padding(.horizontal, 6).background(selected == entry.path ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())}.buttonStyle(.plain).onDrag {
                    guard let workspace = model.state.workspaces.first(where: { $0.id == workspaceId }) else { return NSItemProvider() }
                    return NSItemProvider(object: URL(fileURLWithPath: workspace.path).appendingPathComponent(entry.path) as NSURL)
                }.modifier(ExplorerActions(workspaceId: workspaceId, path: entry.path, directory: false, dirtyPaths: dirtyPaths, onChange: onChange))}
            }
        }.task(id: refreshVersion) {do {let listing: DirectoryListing = try await model.api.get("v1/workspaces/\(workspaceId)/files", query: ["path": path]); entries = listing.entries; error = nil} catch {self.error = error.localizedDescription}}
    }
}
struct FolderRow: View {
    let workspaceId: String; let entry: FileEntry; let selected: String?; let refreshVersion: Int; let dirtyPaths: Set<String>; let onChange: (ExplorerChange) -> Void; let onSelect: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {expanded.toggle()} label: {HStack(spacing: 5) {Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)); Image(systemName: "folder"); Text(entry.name).lineLimit(1); Spacer(minLength: 0)}.font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6).contentShape(Rectangle())}.buttonStyle(.plain)
            .modifier(ExplorerActions(workspaceId: workspaceId, path: entry.path, directory: true, dirtyPaths: dirtyPaths, onChange: onChange))
            if expanded {FileTree(workspaceId: workspaceId, path: entry.path, selected: selected, refreshVersion: refreshVersion, dirtyPaths: dirtyPaths, onChange: onChange, onSelect: onSelect).padding(.leading, 12)}
        }
    }
}

struct NativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var diff: Bool
    var visible: Bool = true
    var wrapsLines: Bool = true
    var language: String? = nil
    var showsLineNumbers = false
    var findRequest = 0
    func makeCoordinator() -> Coordinator {Coordinator(self)}
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = NSTextView(); editor.isRichText = false; editor.isEditable = editable; editor.isSelectable = true; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textColor = .labelColor; editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.delegate = context.coordinator; scroll.documentView = editor
        if showsLineNumbers {scroll.verticalRulerView = CodeLineRuler(editor: editor, scroll: scroll); scroll.hasVerticalRuler = true; scroll.rulersVisible = true}
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.isHidden = !visible
        guard let editor = scroll.documentView as? NSTextView else {return}
        Self.configureWrapping(editor, in: scroll, enabled: wrapsLines)
        if context.coordinator.lastFindRequest != findRequest {
            context.coordinator.lastFindRequest = findRequest
            let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor.performFindPanelAction(item)
        }
        context.coordinator.scheduleHighlight(editor)
        guard editor.string != text else {return}
        let selection = editor.selectedRange(); editor.string = text
        editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        context.coordinator.scheduleHighlight(editor)
        if diff, let storage = editor.textStorage {
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
            var offset = 0
            for line in text.components(separatedBy: "\n") {
                let length = (line as NSString).length
                let color: NSColor? = line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? .secondaryLabelColor : nil
                if let color {storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: offset, length: length))}; offset += length + 1
            }
        }
    }
    static func configureWrapping(_ editor: NSTextView, in scroll: NSScrollView, enabled: Bool) {
        scroll.hasHorizontalScroller = !enabled
        editor.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isHorizontallyResizable = !enabled
        editor.textContainer?.widthTracksTextView = enabled
        editor.textContainer?.containerSize = NSSize(width: enabled ? max(1, scroll.contentSize.width - 16) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if enabled {editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: editor.frame.height))}
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor
        var lastFindRequest = 0
        var highlightTask: Task<Void, Never>?
        var highlightedText: String?
        var highlightedDark: Bool?
        init(_ parent: NativeTextEditor) {self.parent = parent}
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView {parent.text = editor.string; scheduleHighlight(editor)}
        }
        func scheduleHighlight(_ editor: NSTextView) {
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            guard let language = parent.language, !editor.hasMarkedText() else {return}
            let source = editor.string
            let dark = editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard source != highlightedText || dark != highlightedDark else {return}
            highlightedText = source; highlightedDark = dark
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak editor] in
                do {try await Task.sleep(for: .milliseconds(180))} catch {return}
                let result = await CodeHighlighter.shared.highlight(source, language: language, dark: dark)
                guard !Task.isCancelled, let editor, editor.string == source, !editor.hasMarkedText(), let manager = editor.layoutManager else {return}
                let range = NSRange(location: 0, length: (source as NSString).length)
                manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                result?.enumerateAttribute(.foregroundColor, in: range) {color, range, _ in
                    if let color {manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)}
                }
            }
        }
    }
}
