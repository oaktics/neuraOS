import SwiftUI
import AppKit
import ChromiumBridge

enum TerminalLaunchCompletion {
    @MainActor static func attach(_ terminal: TerminalRecord, to binding: Binding<String?>,
                                  stop: (TerminalRecord) async -> Void) async {
        binding.wrappedValue = terminal.id
        // The owner may have disappeared while terminal.open was suspended.
        // Do not leave an unowned process running or assign it to a different tab.
        if binding.wrappedValue != terminal.id {await stop(terminal)}
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
    // Tabs restored from a previous run load their page only when first shown.
    @State private var restoredTabs: Set<String> = []
    @State private var cycle = RecentTabCycle()
    @State private var contentFrame = CGRect.zero
    @State private var clickMonitor: Any?
    @State private var gutterHover = false
    @ObservedObject private var pins = BrowserPins.shared
    /// Files, Git and GitHub have nothing to add while only web pages are on screen.
    private var inspectorAutoHidden: Bool {
        guard model.autoHideInspector, primaryKind == "browser" else {return false}
        return layout.split == nil || layout.split?.kind == "browser"
    }
    private var showsInspector: Bool {
        workspace.hasFolder && (inspectorAutoHidden ? model.inspectorPeek : model.showInspector)
    }
    private func publishInspector() {
        guard model.frontId == workspace.id else {return}
        if model.inspectorAutoHidden != inspectorAutoHidden {model.inspectorAutoHidden = inspectorAutoHidden}
    }
    private var primaryKind: String? {layout.tabs.first {$0.id == layout.selectedId}?.kind}
    private var projectPins: [BrowserPin] {pins.list(workspace.projectId)}
    private static let splitGutter: CGFloat = 7
    private var deletionBlocked: Bool {model.isWorkspaceBlocked(workspace.id)}
    private var storageKey: String {"workspaceTabs.\(workspace.id)"}
    // Each refresh makes the daemon run `git status` and `git branch`. Nobody can
    // see the result while no window is on screen; returning restarts the task.
    private var gitRefreshEnabled: Bool {
        workspace.supportsGit && model.frontId == workspace.id && !deletionBlocked && AppVisibility.shared.visible
    }
    var body: some View {
        core
        .onDisappear {if let clickMonitor {NSEvent.removeMonitor(clickMonitor)}; clickMonitor = nil}
        .onChange(of: model.requestedTab?.tabId) {_, _ in openRequestedTab()}
        .onChange(of: layout.active?.kind) {_, _ in publishActiveKind()}
        .onChange(of: layout.activeId) {_, _ in
            // Keyboard focus follows the tab that commands apply to.
            guard model.frontId == workspace.id, !model.commandBarVisible, let browser = activeBrowser() else {return}
            DispatchQueue.main.async {browser.view.focusContent()}
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) {_ in
            // Control may be released while another app is in front.
            if cycle.active {cycle.finish(); layout.touch(layout.activeId)}
        }
        .onChange(of: model.frontId) {_, _ in publishActiveKind(); publishInspector()}
        .onChange(of: inspectorAutoHidden) {_, _ in publishInspector()}
        .onChange(of: layout.selectedId) {_, _ in if model.frontId == workspace.id, model.inspectorPeek {model.inspectorPeek = false}}
        .onChange(of: projectPins.map(\.id)) {_, _ in dropStalePins()}
        .onChange(of: layout.splitId) {_, _ in persist()}
        .onChange(of: layout.splitFraction) {_, _ in persist()}
    }
    private var core: some View {
        VStack(spacing: 0) {
            if let job = model.deletion(workspace.id) {WorkspaceDeletionStatus(workspace: workspace, job: job)}
            if model.deletionIntents[workspace.id] != nil || model.deletionIntentLoadFailed {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("削除の受付結果が未確認です。起動と編集を停止しています。").font(.callout)
                    Button("受付を確認") {Task {await model.confirmDeletionAcceptance(workspace.id)}}
                        .disabled(!model.connected || model.pendingActions[workspace.id] != nil || model.deletionIntentLoadFailed)
                    Spacer()
                }.padding(16).background(Color.accentColor.opacity(0.07))
            }
            tabBar.disabled(deletionBlocked)
            if workspace.setup != nil {WorktreeSetupStatus(workspace: workspace).disabled(deletionBlocked)}
            Rectangle().fill(Palette.line).frame(height: 1)
            HSplitView {
                contents.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                if showsInspector {inspectorPane.frame(minWidth: 240, idealWidth: 260, maxWidth: 400)}
            }.disabled(deletionBlocked).allowsHitTesting(!deletionBlocked)
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
                if model.pendingActions[workspace.id] != nil || model.deletion(workspace.id)?.inProgress == true {ProgressView().controlSize(.mini)}
                if workspace.supportsGit && !git.changes.isEmpty {
                    Text("\(git.changes.count)件の変更").fixedSize()
                }
                Rectangle().fill(Palette.line).frame(width: 1, height: 12)
                ProviderUsageFooter()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
        }
        .environment(\.openURL, OpenURLAction {url in
            guard !deletionBlocked else {return .discarded}
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {return .systemAction}
            return openURL(url, opener: nil, wanted: model.splitAgentLinks ? .split : .tab, focusSplit: false) ? .handled : .discarded
        })
        .onAppear {restore(); openRequestedTerminal(); openRequestedTab(); publishActiveKind(); publishInspector(); installClickMonitor()}
        .onChange(of: model.state.workspaceTerminals(workspace.id).membership) {_, _ in reconcileTerminals()}
        .onReceive(model.terminalLaunchesChanged) {_ in
            // Keep launch lifecycle events even when several changes share a render turn.
            Task { @MainActor in reconcileTerminals() }
        }
        .onChange(of: model.requestedTerminalId) {_, _ in openRequestedTerminal()}
        .onReceive(model.workspaceUpdated) {id in
            if id == workspace.id {treeVersion += 1; selectedDiff = nil}
        }
        .onReceive(model.workspaceCommands) {request in
            guard !deletionBlocked, request.workspaceId == workspace.id, model.frontId == workspace.id,
                  closingTab == nil else {return}
            switch request.action {
            case .add(let kind): add(kind)
            case .close:
                if let item = layout.active {close(item)}
            case .move(let offset): layout.moveSelection(by: offset)
            case .select(let number): layout.select(number: number)
            case .inspector(let pane): inspector = pane; model.showInspector = true; if inspectorAutoHidden {model.inspectorPeek = true}
            case .open(let url, let placement): openURL(url, opener: nil, wanted: placement)
            case .navigate(let url): navigateActive(url)
            case .focusTab(let id): if layout.tabs.contains(where: {$0.id == id}) {layout.focus(id)}
            case .openPin(let id): openPin(id)
            case .browser(let command): browserCommand(command)
            case .toggleSplit: toggleSplit()
            case .recent(let offset):
                if let id = cycle.step(offset, in: layout), layout.tabs.contains(where: {$0.id == id}) {layout.focus(id, record: false)}
                else {cycle.finish()}
            case .finishRecent: if cycle.active {cycle.finish(); layout.touch(layout.activeId)}
            case .commandBar(let edit): showCommandBar(edit: edit)
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
        .task(id: gitRefreshEnabled) {
            guard gitRefreshEnabled else {return}
            while !Task.isCancelled {
                await refreshGit()
                do {try await Task.sleep(for: .seconds(3))} catch {return}
            }
        }
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            Button {layout.focus(nil)} label: {
                Image(systemName: "house").frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(layout.selectedId == nil ? Color.accentColor : Color.secondary)
            .background(layout.selectedId == nil ? Color.primary.opacity(0.055) : .clear)
            .accessibilityLabel("ホーム").help("ホームに戻る")
            Divider().frame(height: 18)
            if !projectPins.isEmpty {
                HStack(spacing: 2) {ForEach(projectPins) {pin in pinButton(pin)}}.padding(.horizontal, 6)
                Divider().frame(height: 18)
            }
            ScrollViewReader {proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(layout.listed) {item in tabItem(item)}
                    }
                }.scrollIndicators(.hidden)
                .onChange(of: layout.activeId) {_, id in if let id {proxy.scrollTo(id)}}
            }
            if layout.split != nil {
                Button {toggleSplit()} label: {Image(systemName: "rectangle").frame(width: 28, height: 32).contentShape(Rectangle())}
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("分割を解除（⌘\\）").accessibilityLabel("分割を解除")
            }
            Menu {addTabButtons} label: {Image(systemName: "plus").frame(width: 28, height: 32)}
                .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8).help("タブを追加。⌘Tで検索・URL・Terminalをまとめて開けます")
        }.frame(height: 32)
    }
    private func tabItem(_ item: WorkspaceTab) -> some View {
        let title = item.displayTitle(terminal: model.terminal(id: item.terminalId))
        let active = layout.activeId == item.id
        let shown = active || layout.selectedId == item.id || layout.split?.id == item.id
        return HStack(spacing: 8) {
            Button {
                if NSEvent.modifierFlags.contains(.option) {layout.toggleSplit(item.id)} else {layout.focus(item.id)}
            } label: {
                HStack(spacing: 6) {
                    if item.kind == "browser" {FaviconView(address: item.browserURL, size: 13)} else {Image(systemName: item.icon)}
                    Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
                    if let path = item.filePath, documents[path]?.dirty == true {Circle().frame(width: 5, height: 5)}
                    TerminalRunningIndicator(terminalId: item.terminalId)
                }.padding(.leading, 10).frame(height: 31).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).help((item.filePath ?? item.browserURL ?? title) + "\n⌥クリックで右に並べて表示")
            Button {close(item)} label: {Image(systemName: "xmark").font(.system(size: 9)).frame(width: 22, height: 28).contentShape(Rectangle())}.buttonStyle(.plain).disabled(model.isTerminalStarting(item.id)).accessibilityLabel("\(title)を閉じる").help("\(title)を閉じる" + (active ? "（⌘W）" : ""))
        }
        .font(.system(size: 12)).foregroundStyle(shown ? .primary : .secondary)
        .background(shown ? Color.primary.opacity(0.055) : .clear)
        .overlay(alignment: .bottom) {if shown {Rectangle().fill(active ? Color.accentColor : Color.secondary.opacity(0.5)).frame(height: 2)}}
        .contextMenu {
            Button(layout.split?.id == item.id ? "分割を解除" : "右に並べて表示") {layout.toggleSplit(item.id)}
            if item.kind == "browser" {
                Button("このプロジェクトにピン留め") {togglePin(item.id, address: item.browserURL ?? "", title: item.browserTitle ?? "")}
                    .disabled(BrowserModel.navigationURL(item.browserURL ?? "")?.host == nil)
            }
            Divider()
            Button("サイドバーに固定") {fixToSidebar(item)}
                .disabled(!(item.kind == "browser" ? BrowserModel.navigationURL(item.browserURL ?? "")?.host != nil : item.isTerminal && item.terminalId != nil))
            Divider()
            Button("タブを閉じる") {close(item)}.disabled(model.isTerminalStarting(item.id))
        }
        .draggable(item.id)
        .dropDestination(for: String.self) {ids, _ in
            guard let id = ids.first, layout.tabs.contains(where: {$0.id == id}) else {return false}
            layout.move(id, before: item.id)
            return true
        }
        .id(item.id)
    }
    private func pinButton(_ pin: BrowserPin) -> some View {
        let tab = layout.tabs.first {$0.pinId == pin.id}
        let active = tab != nil && layout.activeId == tab?.id
        let shown = tab != nil && (active || layout.selectedId == tab?.id || layout.split?.id == tab?.id)
        return Button {
            if NSEvent.modifierFlags.contains(.option), let tab {layout.toggleSplit(tab.id)} else {openPin(pin.id)}
        } label: {
            FaviconView(address: pin.url, size: 16)
                .frame(width: 28, height: 26)
                .background(shown ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    if tab != nil {Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.6)).frame(width: 10, height: 2).offset(y: 3)}
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help("\(pin.title)\n\(pin.url)").accessibilityLabel("ピン: \(pin.title)")
        .contextMenu {
            Button("開く") {openPin(pin.id)}
            if let tab {
                Button("保存したページに戻る") {
                    if let url = URL(string: pin.url) {BrowserModel.live("\(workspace.id).\(tab.id)")?.navigate(url.absoluteString)}
                    layout.focus(tab.id)
                }
                Button("現在のページをピンの行き先にする") {
                    if let url = tab.browserURL, BrowserModel.navigationURL(url)?.host != nil {
                        pins.update(pin.id, in: workspace.projectId, url: url, title: tab.browserTitle ?? "")
                    }
                }
                Button(layout.split?.id == tab.id ? "分割を解除" : "右に並べて表示") {layout.toggleSplit(tab.id)}
                Button("ページを閉じる（ピンは残す）") {close(tab)}
            }
            Divider()
            Button("ピン留めを解除") {pins.remove(pin.id, from: workspace.projectId)}
        }
        .draggable("pin." + pin.id)
        .dropDestination(for: String.self) {ids, _ in
            guard let id = ids.first, id.hasPrefix("pin.") else {return false}
            pins.move(String(id.dropFirst(4)), before: pin.id, in: workspace.projectId)
            return true
        }
    }
    @ViewBuilder private var addTabButtons: some View {
        Button {add(model.conversationProvider(for: workspace))} label: {Label("新しい会話", systemImage: "bubble.left")}
        Button {add("codex")} label: {Label("Codex", systemImage: "sparkle")}
        Button {add("claude")} label: {Label("Claude Code", systemImage: "asterisk")}
        Button {add("shell")} label: {Label("Terminal", systemImage: "terminal")}
        Button {add("browser")} label: {Label("Browser", systemImage: "globe")}

    }
    // Keep the home mounted so switching tabs preserves the selected task and unsent instructions.
    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label("ホーム", systemImage: "house").font(.title2.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {addTabButtons}
                    VStack(alignment: .leading, spacing: 8) {addTabButtons}
                }.controlSize(.large)
            }.padding(20)
            Divider()
            if model.state.features?.contains("agent.supervision") == true {
                AgentSupervisor(workspace: workspace, visible: layout.selectedId == nil && model.frontId == workspace.id && !deletionBlocked)
            } else {
                Text("新しい作業を始めましょう。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var contents: some View {
        GeometryReader {geometry in
            let size = geometry.size
            let splitTab = layout.split
            // Explicit CGFloat throughout: older compilers do not mix Double and CGFloat here.
            let gutter: CGFloat = splitTab == nil ? 0 : Self.splitGutter
            let available: CGFloat = size.width - gutter
            let proposed: CGFloat = available * CGFloat(layout.fraction)
            let leftWidth: CGFloat = splitTab == nil ? size.width : max(160, min(available - 160, proposed))
            let rightWidth: CGFloat = max(0, available - leftWidth)
            let frontmost = model.frontId == workspace.id && !deletionBlocked
            ZStack(alignment: .topLeading) {
                home
                    .frame(width: leftWidth, height: size.height)
                    .opacity(layout.selectedId == nil ? 1 : 0)
                    .allowsHitTesting(layout.selectedId == nil && model.frontId == workspace.id)
                    .accessibilityHidden(layout.selectedId != nil || model.frontId != workspace.id)
                ForEach(layout.tabs) {item in
                    let right = splitTab?.id == item.id
                    let shown = right || layout.selectedId == item.id
                    let visible = shown && frontmost
                    Group {
                        if item.isTerminal {TerminalPane(workspace: workspace, tabId: item.id, provider: item.kind, terminalId: $layout.tabValue(item.id, \.terminalId), visible: visible, active: layout.activeId == item.id, onOpenURL: {url in
                            guard !deletionBlocked else {return}
                            // The page appears beside the conversation; typing stays in the terminal.
                            openURL(url, opener: item.id, wanted: model.splitAgentLinks ? .split : .tab, focusSplit: false)
                        })}
                        else if item.kind == "file", let path = item.filePath {
                            FilePane(workspace: workspace, path: path, visible: visible, active: layout.activeId == item.id, openFile: {layout.openFile($0)}, documents: $documents).id(path)
                        }
                        else if item.kind == "browser" {
                            BrowserPane(storageId: "\(workspace.id).\(item.id)", workspaceId: workspace.id, projectId: workspace.projectId, visible: visible,
                                        title: $layout.tabValue(item.id, \.browserTitle), url: $layout.tabValue(item.id, \.browserURL),
                                        pin: item.pinId.flatMap {id in projectPins.first {$0.id == id}}, split: splitTab != nil,
                                        eager: !restoredTabs.contains(item.id), view: popupViews[item.id], actions: browserActions(item))
                        }
                    }
                    // Hidden tabs keep the full width so showing or hiding a split does not resize them.
                    .frame(width: right ? rightWidth : shown ? leftWidth : size.width, height: size.height)
                    .offset(x: right ? leftWidth + gutter : 0)
                    .opacity(shown ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                }
                if primaryKind == "diff" {
                    Group {
                        if let diff = selectedDiff {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(diff.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(diff.path).padding(.horizontal, 8).frame(height: 28)
                                Divider()
                                NativeTextEditor(text: .constant(diff.content), editable: false, diff: true)
                            }
                        } else {Text("右のGit一覧から差分を選択").foregroundStyle(.secondary)}
                    }.frame(width: leftWidth, height: size.height)
                }
                if splitTab != nil {
                    // A real gap between the panes: native page and terminal views would cover an overlay.
                    Rectangle().fill(Palette.line).frame(width: 1, height: size.height)
                        .frame(width: gutter, height: size.height)
                        .contentShape(Rectangle())
                        .offset(x: leftWidth)
                        .onHover {inside in
                            guard inside != gutterHover else {return}
                            gutterHover = inside
                            if inside {NSCursor.resizeLeftRight.push()} else {NSCursor.pop()}
                        }
                        .onDisappear {if gutterHover {gutterHover = false; NSCursor.pop()}}
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("workspace.contents")).onChanged {value in
                            guard size.width > gutter else {return}
                            let position: CGFloat = (value.location.x - gutter / 2) / (size.width - gutter)
                            layout.splitFraction = min(0.8, max(0.2, Double(position)))
                        })
                        .help("ドラッグして幅を調整")
                }
            }
            .coordinateSpace(name: "workspace.contents")
            .onAppear {contentFrame = geometry.frame(in: .global)}
            .onChange(of: geometry.frame(in: .global)) {_, frame in contentFrame = frame}
        }
    }
    private func browserActions(_ item: WorkspaceTab) -> BrowserPaneActions {
        BrowserPaneActions(
            popup: {view, url in openBrowserPopup(view, url: url, opener: item.id)},
            openTab: {address, background in
                guard !deletionBlocked, let url = BrowserModel.navigationURL(address) else {return}
                openURL(url, opener: item.id, wanted: background ? .background : .tab)
            },
            closed: {remove(item)},
            editAddress: {_ in layout.focus(item.id); showCommandBar(edit: true)},
            togglePin: {address, title in togglePin(item.id, address: address, title: title)},
            toggleSplit: {if layout.split != nil {toggleSplit()} else {layout.toggleSplit(item.id)}}
        )
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
                GitHubSidebar(workspace: workspace, visible: showsInspector && model.frontId == workspace.id, openTerminal: {add("shell")})
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
        layout.normalize()
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
    /// A page opened from the right pane stays there; from the left pane it may go beside it.
    private func placement(_ wanted: BrowserPlacement, opener: String?) -> BrowserPlacement {
        let fromSplit = opener != nil && opener == layout.split?.id
        switch wanted {
        case .background: return .background
        case .tab: return fromSplit ? .split : .tab
        case .split:
            // Too narrow to show two panes usefully: open an ordinary tab instead.
            if fromSplit || contentFrame.width < 720 {return .tab}
            return .split
        }
    }
    @discardableResult
    private func openURL(_ url: URL, opener: String?, wanted: BrowserPlacement, focusSplit: Bool = true) -> Bool {
        guard !deletionBlocked else {return false}
        return layout.openBrowser(url, workspaceId: workspace.id, opener: opener, placement: placement(wanted, opener: opener), focusSplit: focusSplit)
    }
    private func openBrowserPopup(_ view: NCChromiumView, url: String, opener: String) -> Bool {
        guard !deletionBlocked else {return false}
        var item = WorkspaceTab(kind: "browser", number: (layout.tabs.filter {$0.kind == "browser"}.map(\.number).max() ?? 0) + 1)
        item.openerId = opener
        popupViews[item.id] = view
        UserDefaults.standard.set(url, forKey: "browser.\(workspace.id).\(item.id)")
        layout.insert(item, placement: placement(view.openedInBackground ? .background : .tab, opener: opener))
        return true
    }
    private func add(_ kind: String) {
        guard !deletionBlocked else {return}
        Diagnostics.shared.record("action.add-tab")
        let item = WorkspaceTab(kind: kind, number: (layout.tabs.filter {$0.kind == kind}.map(\.number).max() ?? 0) + 1)
        layout.tabs.append(item); layout.focus(item.id)
    }
    private func showUtility(_ kind: String) {
        if let item = layout.tabs.first(where: {$0.kind == kind}) {layout.focus(item.id)} else {add(kind)}
    }
    private func close(_ item: WorkspaceTab) {
        guard !deletionBlocked else {return}
        guard !model.isTerminalStarting(item.id) else {return}
        Diagnostics.shared.record("action.close-tab")
        if model.terminal(id: item.terminalId)?.status == "running" {closingTab = item} else {remove(item)}
    }
    private func remove(_ item: WorkspaceTab) {
        popupViews.removeValue(forKey: item.id)
        layout.close(item.id)
    }
    /// Move a tab to the sidebar's fixed tabs. A terminal or agent keeps running; only its place changes.
    private func fixToSidebar(_ item: WorkspaceTab) {
        guard !deletionBlocked, !model.isTerminalStarting(item.id) else {return}
        var fixed = FixedTab(kind: item.kind, title: item.displayTitle(terminal: model.terminal(id: item.terminalId)), spaceId: model.sidebarSpaces.active.id)
        if item.kind == "browser" {
            guard let url = BrowserModel.navigationURL(item.browserURL ?? ""), url.host != nil else {return}
            fixed.url = url.absoluteString
        } else {
            guard item.isTerminal, let terminalId = item.terminalId else {return}
            fixed.workspaceId = workspace.id; fixed.terminalId = terminalId
        }
        let added = FixedTabs.shared.add(fixed)
        remove(item)
        model.openFixed(added.id)
    }
    /// Terminals of this workspace that belong among its tabs: fixed tabs show their own.
    private var listedTerminals: [TerminalRecord] {
        model.state.terminals(in: workspace.id).filter {!FixedTabs.shared.owns(terminal: $0.id)}
    }
    private func toggleSplit() {
        if layout.split != nil {layout.splitId = nil; layout.splitFocused = nil}
        else if let id = layout.activeId {layout.toggleSplit(id)}
    }
    private func openPin(_ id: String) {
        guard !deletionBlocked, let pin = pins.pin(id, in: workspace.projectId) else {return}
        if let tab = layout.tabs.first(where: {$0.pinId == id}) {layout.focus(tab.id); return}
        guard BrowserModel.navigationURL(pin.url) != nil else {return}
        var tab = WorkspaceTab(kind: "browser", number: (layout.tabs.filter {$0.kind == "browser"}.map(\.number).max() ?? 0) + 1)
        tab.pinId = id; tab.browserURL = pin.url; tab.browserTitle = pin.title
        UserDefaults.standard.set(pin.url, forKey: "browser.\(workspace.id).\(tab.id)")
        // Pinned pages sit before ordinary tabs, in pin order.
        layout.tabs.insert(tab, at: layout.tabs.prefix {$0.pinId != nil}.count)
        layout.focus(tab.id)
    }
    private func togglePin(_ tabId: String, address: String, title: String) {
        guard let index = layout.tabs.firstIndex(where: {$0.id == tabId}) else {return}
        if let pinId = layout.tabs[index].pinId {
            pins.remove(pinId, from: workspace.projectId)
            layout.tabs[index].pinId = nil
            return
        }
        guard let url = BrowserModel.navigationURL(address), url.host != nil else {return}
        let pin = pins.add(url: url.absoluteString, title: title, to: workspace.projectId)
        if !layout.tabs.contains(where: {$0.pinId == pin.id}) {layout.tabs[index].pinId = pin.id}
    }
    /// A pin removed in any worktree releases its page here as an ordinary tab.
    private func dropStalePins() {
        let ids = Set(projectPins.map(\.id))
        for index in layout.tabs.indices {
            if let pinId = layout.tabs[index].pinId, !ids.contains(pinId) {layout.tabs[index].pinId = nil}
        }
    }
    private func activeBrowser() -> BrowserModel? {
        guard let tab = layout.active, tab.kind == "browser" else {return nil}
        return BrowserModel.live("\(workspace.id).\(tab.id)")
    }
    private func navigateActive(_ url: URL) {
        guard !deletionBlocked else {return}
        if let browser = activeBrowser() {browser.loaded = true; browser.navigate(url.absoluteString); browser.view.focusContent()}
        else {openURL(url, opener: nil, wanted: .tab)}
    }
    private func browserCommand(_ command: BrowserCommand) {
        guard !deletionBlocked, let tab = layout.active, tab.kind == "browser", let browser = activeBrowser() else {return}
        if command == .togglePin {togglePin(tab.id, address: browser.address, title: browser.title)} else {browser.perform(command)}
    }
    private func showCommandBar(edit: Bool) {
        guard !deletionBlocked, let window = NSApp.windows.first(where: {$0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible}) ?? NSApp.mainWindow else {return}
        let browser = activeBrowser()
        let context = CommandBarContext(editing: edit && browser != nil, currentURL: browser?.address ?? "", workspaceId: workspace.id,
                                        conversationProvider: model.conversationProvider(for: workspace),
                                        tabs: model.browserTabs(), pins: projectPins,
                                        fixed: FixedTabs.shared.tabs, workspaces: model.commandBarWorkspaces().filter {$0.id != workspace.id})
        CommandBarPanel.shared.show(over: window, context: context) {action, split in
            guard !deletionBlocked else {return}
            switch action {
            case .navigate(let url): navigateActive(url)
            case .open(let url): openURL(url, opener: nil, wanted: split ? .split : .tab)
            case .focusTab(let workspaceId, let tabId):
                if workspaceId == workspace.id {layout.focus(tabId)}
                else {model.requestedTab = (workspaceId, tabId); model.select(workspaceId)}
            case .openPin(let id): openPin(id)
            case .add(let kind): add(kind)
            case .openFixed(let id): model.openFixed(id)
            case .focusWorkspace(let id): model.select(id)
            }
        }
    }
    private func publishActiveKind() {
        guard model.frontId == workspace.id else {return}
        let kind = layout.active?.kind
        if model.activeTabKind != kind {model.activeTabKind = kind}
    }
    private func openRequestedTab() {
        guard let request = model.requestedTab, request.workspaceId == workspace.id else {return}
        restore()
        if layout.tabs.contains(where: {$0.id == request.tabId}) {layout.focus(request.tabId)}
        model.requestedTab = nil
    }
    /// With two panes on screen, a click decides which one keyboard commands apply to.
    private func installClickMonitor() {
        guard clickMonitor == nil else {return}
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {event in
            MainActor.assumeIsolated {
                guard model.frontId == workspace.id, layout.split != nil, let content = event.window?.contentView,
                      event.window?.identifier?.rawValue.hasPrefix("main") == true else {return}
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                guard contentFrame.contains(point) else {return}
                let boundary: CGFloat = contentFrame.minX + (contentFrame.width - Self.splitGutter) * CGFloat(layout.fraction)
                let right = point.x > boundary + Self.splitGutter
                if point.x < boundary || right, (layout.splitFocused == true) != right {layout.splitFocused = right}
            }
            return event
        }
    }
    private func openRequestedTerminal() {
        guard let id = model.requestedTerminalId,
              let terminal = model.terminal(id: id), terminal.workspaceId == workspace.id else {return}
        // A terminal shown by a fixed tab is opened there, never as a second pane among the tabs.
        if let fixed = FixedTabs.shared.tab(owning: id) {
            model.requestedTerminalId = nil
            model.openFixed(fixed.id)
            return
        }
        restore()
        if let tab = layout.tabs.first(where: {$0.terminalId == id}) {layout.focus(tab.id)}
        else {
            let tab = WorkspaceTab(kind: terminal.provider, number: (layout.tabs.filter {$0.kind == terminal.provider}.map(\.number).max() ?? 0) + 1, terminalId: id)
            layout.tabs.append(tab); layout.focus(tab.id)
        }
        model.requestedTerminalId = nil
        persist()
    }
    private func restore() {
        guard !restored else {return}; restored = true
        let saved = UserDefaults.standard.data(forKey: storageKey).flatMap {try? JSONDecoder().decode(WorkspaceTabState.self, from: $0)}
        layout = saved ?? WorkspaceTabState()
        layout.migrateAgentTabs()
        restoredTabs = Set(layout.tabs.filter {$0.kind == "browser"}.map(\.id))
        inspector = UserDefaults.standard.string(forKey: "inspector.\(workspace.id)") ?? "files"
        if layout.tabs.contains(where: {$0.kind == "github" && $0.id == layout.selectedId}) {
            inspector = "github"; model.showInspector = true
        }
        documents = DraftCache.shared.load(workspace.id)
        let wasFiles = layout.tabs.first {$0.id == layout.selectedId}?.kind == "files"
        layout.tabs.removeAll {$0.kind == "github" || $0.kind == "files"}
        let previousSelection = layout.selectedId
        for path in documents.keys.sorted() where documents[path]?.dirty == true {layout.openFile(path)}
        if !wasFiles, previousSelection == nil || layout.tabs.contains(where: {$0.id == previousSelection}) {layout.selectedId = previousSelection}
        // Recover running sessions, including sessions opened while this UI was disconnected.
        let terminals = listedTerminals
        seenTerminalIds = Set(terminals.map(\.id))
        for terminal in terminals.filter({terminal in terminal.status == "running" || (saved == nil && terminals.last(where: {$0.provider == terminal.provider})?.id == terminal.id)}) {
            if !layout.tabs.contains(where: {$0.terminalId == terminal.id}) {
                let number = (layout.tabs.filter {$0.kind == terminal.provider}.map(\.number).max() ?? 0) + 1
                layout.tabs.append(WorkspaceTab(kind: terminal.provider, number: number, terminalId: terminal.id))
            }
        }
        layout.normalize()
        dropStalePins()
        persist()
    }
    private func reconcileTerminals() {
        guard restored else {return}
        // A fixed tab that is starting its terminal publishes the record before it owns it.
        guard !FixedTabs.shared.startingTabIds(in: workspace.id).contains(where: {model.isTerminalStarting($0)}) else {return}
        layout.reconcileTerminals(listedTerminals,
                                  seen: &seenTerminalIds, startingTabs: model.startingTerminalTabs)
    }
    private func persist() {guard restored, let data = try? JSONEncoder().encode(layout) else {return}; UserDefaults.standard.set(data, forKey: storageKey)}
    private func refreshGit() async {
        guard workspace.supportsGit else {return}
        do {
            let next: GitStatus = try await model.api.get("v1/workspaces/\(workspace.id)/git")
            guard !Task.isCancelled else {return}
            if git != next {git = next}
            if gitError != nil {gitError = nil}
        } catch {
            guard !Task.isCancelled else {return}
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
    var active = true
    let onOpenURL: (URL) -> Void
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
                if visible || hasBeenVisible {NativeTerminal(onOpenURL: onOpenURL, terminal: terminal, api: model.api, visible: visible, active: active, onError: {model.report($0)}).padding(.horizontal, 4).frame(maxWidth: .infinity, maxHeight: .infinity).id(terminal.id)}
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
            if let terminal = await model.openTerminal(workspace, provider: provider, resume: resume) {
                await TerminalLaunchCompletion.attach(terminal, to: $terminalId) {terminal in
                    await model.stopTerminal(terminal)
                }
            }
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
        let editor = NSTextView(); editor.isRichText = false; editor.isEditable = editable && visible; editor.isSelectable = true; editor.allowsUndo = true
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
        Self.configureInteraction(editor, visible: visible, editable: editable)
        Self.configureWrapping(editor, in: scroll, enabled: wrapsLines)
        if context.coordinator.lastFindRequest != findRequest {
            context.coordinator.lastFindRequest = findRequest
            let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
            editor.performFindPanelAction(item)
        }
        context.coordinator.scheduleHighlight(editor)
        guard context.coordinator.differs(editor, from: text) else {return}
        let selection = editor.selectedRange(); editor.string = text
        context.coordinator.synced = text
        editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        context.coordinator.scheduleHighlight(editor)
        if diff, let storage = editor.textStorage {Self.colorDiff(storage, text: text)}
    }
    static func colorDiff(_ storage: NSTextStorage, text: String) {
        // One editing transaction for the whole diff. Outside it every changed
        // line runs its own processEditing pass, which invalidates layout from
        // that line onward: quadratic, and seconds of main-thread time by 10k lines.
        storage.beginEditing(); defer {storage.endEditing()}
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = line.utf16.count
            let color: NSColor? = line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? .secondaryLabelColor : nil
            if let color {storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: offset, length: length))}; offset += length + 1
        }
    }
    static func configureInteraction(_ editor: NSTextView, visible: Bool, editable: Bool) {
        editor.isEditable = editable && visible
        if !editor.isEditable, editor.window?.firstResponder === editor {editor.window?.makeFirstResponder(nil)}
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
        // The editor's contents as a native Swift string, when known. `editor.string`
        // is a bridged NSString: every comparison against it walks UTF-16, and a
        // bridged value stored in the document made each later `dirty`/equality
        // check on the keystroke path equally slow.
        var synced: String?
        init(_ parent: NativeTextEditor) {self.parent = parent}
        func differs(_ editor: NSTextView, from text: String) -> Bool {
            if let synced {return synced != text}
            guard editor.string != text else {synced = text; return false}
            return true
        }
        func textDidChange(_ notification: Notification) {
            // An unreported change leaves the cache unknown; the next update compares the editor itself.
            guard parent.editable && parent.visible else {synced = nil; return}
            if let editor = notification.object as? NSTextView {
                var value = editor.string; value.makeContiguousUTF8()
                synced = value; parent.text = value; scheduleHighlight(editor)
            }
        }
        func scheduleHighlight(_ editor: NSTextView) {
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            guard let language = parent.language, !editor.hasMarkedText() else {return}
            let source = synced ?? editor.string
            let dark = editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard source != highlightedText || dark != highlightedDark else {return}
            highlightedText = source; highlightedDark = dark
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self, weak editor] in
                do {try await Task.sleep(for: .milliseconds(180))} catch {return}
                let result = await CodeHighlighter.shared.highlight(source, language: language, dark: dark)
                guard !Task.isCancelled, let self, let editor, (self.synced ?? editor.string) == source, !editor.hasMarkedText(), let manager = editor.layoutManager else {return}
                let range = NSRange(location: 0, length: (source as NSString).length)
                manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                result?.enumerateAttribute(.foregroundColor, in: range) {color, range, _ in
                    if let color {manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)}
                }
            }
        }
    }
}
