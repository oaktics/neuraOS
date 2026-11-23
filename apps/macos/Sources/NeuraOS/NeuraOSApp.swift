import SwiftUI
import AppKit
import Darwin
import ChromiumBridge
import Highlighter

@main enum NeuraOSMain {
    static func main() {
        NCPrepareApplication()
        if let index = CommandLine.arguments.firstIndex(of: "--sleep-history-fixture"), CommandLine.arguments.count > index + 1 {
            SleepHistoryFixture.run(CommandLine.arguments[index + 1]); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--extensions-smoke"), CommandLine.arguments.count > index + 3 {
            exit(NCRunExtensionsSmoke(CommandLine.arguments[index + 1], CommandLine.arguments[index + 2], Int32(CommandLine.arguments[index + 3]) ?? 0, ExtensionSmokeAccessory()))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--browser-fixture"), CommandLine.arguments.count > index + 1 {
            BrowserFixture.run(CommandLine.arguments[index + 1]);return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--download-smoke"), CommandLine.arguments.count > index + 2 {
            exit(NCRunDownloadSmoke(CommandLine.arguments[index + 1], CommandLine.arguments[index + 2], NSHostingView(rootView: BrowserDownloadsButton().padding(8))))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--chromium-smoke"), CommandLine.arguments.count > index + 2 {
            exit(NCRunChromiumSmoke(CommandLine.arguments[index + 1], CommandLine.arguments[index + 2]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--reliability-smoke"), CommandLine.arguments.count > index + 1 {
            ReliabilitySmoke.run(report: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if !CommandLine.arguments.contains("--check-bundled-resources") {
            Diagnostics.shared.start()
            if let error = NCInitializeChromium() {NSLog("%@", error)}
        }
        NeuraOSApp.main()
    }
}

struct NeuraOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()
    @State private var daemonRestart = DaemonRestart()
    @StateObject private var updater = AppUpdater()
    @Environment(\.openWindow) private var openWindow
    init() {
        // Exercise the actual packaged executable without opening a window or
        // starting the daemon. Release smoke checks run this after relocation.
        if CommandLine.arguments.contains("--check-bundled-resources") {
            let available = GitHubMarkdownHTML.resourcesAvailable
            if !available {
                FileHandle.standardError.write(Data("Missing GitHub Markdown resources\n".utf8))
            }
            // Creating a highlighter aborted installed builds when its bundle was looked up through SwiftPM.
            let highlights = Highlighter()?.highlight("let x = 1", as: "swift") != nil
            if !highlights {
                FileHandle.standardError.write(Data("Missing syntax highlighting resources\n".utf8))
            }
            exit(available && highlights ? 0 : 1)
        }
    }
    var body: some Scene {
        // The first scene is opened on launch. Keep Settings after the main window.
        Window("neuraOS", id: "main") {
            RootView().environment(model).frame(minWidth: 900, minHeight: 580)
                .sheet(isPresented: $updater.presented) {AppUpdateView(updater: updater)}
                .task {await updater.bootstrap()}
                .alert("Daemon", isPresented: Binding(get: {daemonRestart.message != nil}, set: {if !$0 {daemonRestart.message = nil}})) {
                    Button("OK") {daemonRestart.message = nil}
                } message: {Text(daemonRestart.message ?? "")}
        }
        .defaultSize(width: 1380, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .help) {
                Button("今おかしかった：診断情報を保存…") {DiagnosticReport.save()}
            }
            CommandGroup(after: .appInfo) {
                Button("アップデートを確認…") {updater.checkForUpdates()}
                    .disabled(updater.updatesEnabled && !updater.canCheckForUpdates || updater.busy || daemonRestart.busy)
                if updater.updatesEnabled {Toggle("アップデートを自動で確認", isOn: $updater.automaticallyChecks)}
                Button(daemonRestart.busy ? "Daemonを再起動中…" : "Daemonを再起動…") {openWindow(id: "main"); daemonRestart.request(model: model)}
                    .disabled(daemonRestart.busy || updater.busy)
            }
            CommandGroup(replacing: .newItem) {
                Button("新しいWorkspace…") {model.showNewSpace = true}.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("新しいプロジェクト…") {model.showNewProject = true}.keyboardShortcut("n", modifiers: [.command, .option]).disabled(!model.connected || !model.supportsFolderless)
                Button("フォルダを開く…") {model.addProject()}.keyboardShortcut("o")
                Button("新しい作業…") {model.showNewWorkspace = true}.keyboardShortcut("n").disabled(model.gitProjects.isEmpty)
            }
            WorkspaceCommands(model: model)
            AgentNotificationCommands()
            CommandMenu("表示") {
                Button("メイン画面を開く") {openWindow(id: "main")}
                Button("前のWorkspace") {if let id = model.sidebarSpaces.adjacent(-1) {model.switchSpace(id)}}.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(model.sidebarSpaces.adjacent(-1) == nil)
                Button("次のWorkspace") {if let id = model.sidebarSpaces.adjacent(1) {model.switchSpace(id)}}.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(model.sidebarSpaces.adjacent(1) == nil)
                Button(model.showSidebar ? "左サイドバーを閉じる" : "左サイドバーを開く") {model.showSidebar.toggle()}.keyboardShortcut("s", modifiers: [.command, .control])
                Button(model.inspectorShown ? "右サイドバーを閉じる" : "右サイドバーを開く") {model.toggleInspector()}.keyboardShortcut("\\", modifiers: [.command, .option]).disabled(model.selected == nil || model.fixedId != nil)
                Toggle("ブラウザ表示中は右サイドバーを自動で隠す", isOn: Binding(get: {model.autoHideInspector}, set: {model.autoHideInspector = $0}))
            }
        }
        Settings {
            TabView {
                AgentSleepSettings(controller: model.agentSleep).tabItem {Label("スリープ", systemImage: "moon")}
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {false}
    func applicationWillTerminate(_ notification: Notification) {DraftCache.shared.flush(); Diagnostics.shared.stop()}
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {sender.windows.first?.makeKeyAndOrderFront(nil)}; return true
    }
}

enum Palette {
    static let surface = Color(nsColor: NSColor(name: nil) {appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.105, alpha: 1) : NSColor(white: 0.985, alpha: 1)})
    static let line = Color.primary.opacity(0.08)
    /// A shade apart from the work area, so the sidebar reads as a separate surface.
    static let sidebar = Color(nsColor: NSColor(name: nil) {appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.135, alpha: 1) : NSColor(white: 0.955, alpha: 1)})
}
struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {model.showSidebar.toggle()} label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(model.showSidebar ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(model.showSidebar ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.showSidebar ? "左サイドバーを閉じる（⌃⌘S）" : "左サイドバーを開く（⌃⌘S）")
                .accessibilityLabel(model.showSidebar ? "左サイドバーを閉じる" : "左サイドバーを開く")
                .padding(.leading, 72)
                if let fixed = model.fixedId.flatMap({FixedTabs.shared.tab($0)}) {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(fixed.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if fixed.isTerminal, let workspace = model.state.workspaces.first(where: {$0.id == fixed.workspaceId}) {
                        Text("/").foregroundStyle(.quaternary)
                        Text((model.state.projects.first {$0.id == workspace.projectId}?.name ?? "") + " · " + workspace.name).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(model.state.projects.first(where: {$0.id == model.selected?.projectId})?.name ?? "neuraOS")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let selected = model.selected {Text("/").foregroundStyle(.quaternary); Text(selected.name).foregroundStyle(.secondary).lineLimit(1)}
                }
                Spacer()
                if !model.pendingActions.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1)) {context in
                        Text(model.pendingActions.keys.sorted().map {key in "\(model.pendingActions[key] ?? "")（\(Int(max(0, context.date.timeIntervalSince(model.actionStarted[key] ?? context.date))))秒）"}.joined(separator: "・")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView().controlSize(.small)
                }
                Circle().fill(model.connected ? Color.green.opacity(0.8) : Color.orange).frame(width: 6, height: 6)
                Text(model.connected ? "このMac" : "接続待ち").font(.system(size: 11)).foregroundStyle(.secondary)
                if model.selected?.hasFolder == true, model.fixedId == nil {
                    Button {model.toggleInspector()} label: {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(model.inspectorShown ? Color.accentColor : Color.secondary)
                            .frame(width: 30, height: 28)
                            .background(model.inspectorShown ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.inspectorShown ? "右サイドバーを閉じる（⌘⌥\\）" : model.inspectorAutoHidden ? "右サイドバーを開く（⌘⌥\\）。ブラウザ表示中は自動で隠れています" : "右サイドバーを開く（⌘⌥\\）")
                    .accessibilityLabel(model.inspectorShown ? "右サイドバーを閉じる" : "右サイドバーを開く")
                    .padding(.leading, 6)
                }
            }.padding(.horizontal, 10).frame(height: 38)
            Rectangle().fill(Palette.line).frame(height: 1)
            HSplitView {
                if model.showSidebar {Sidebar().frame(minWidth: 210, idealWidth: 248, maxWidth: 320)}
                ZStack {
                    if model.selected == nil, model.fixedId == nil {WelcomeView()}
                    // Keep each workspace mounted: its terminal, editor draft and browser remain intact.
                    ForEach(model.state.workspaces.filter {model.openedIds.contains($0.id)}) {workspace in
                        WorkspaceView(workspace: workspace)
                            .opacity(workspace.id == model.frontId ? 1 : 0)
                            .allowsHitTesting(workspace.id == model.frontId)
                            .accessibilityHidden(workspace.id != model.frontId)
                    }
                    // Fixed tabs cover the worktree while shown and stay alive once opened.
                    FixedTabPanes()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.frontId == nil {
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack {
                    Spacer(minLength: 0)
                    ProviderUsageFooter()
                }.padding(.horizontal, 12).frame(height: 28)
            }
            if !model.connected {
                HStack {Image(systemName: "network.slash"); Text("Daemonへ再接続しています。作業の状態は接続後に更新されます。"); Spacer(); Button("再接続") {Task {await model.refresh()}}}
                    .font(.system(size: 11)).padding(10).background(Color.orange.opacity(0.08))
            }
        }
        .background(Palette.surface)
        .onAppear {KeyboardRouter.install(model)}
        .task(id: model.connected && model.state.features?.contains("provider.usage") == true) {
            guard model.connected, model.state.features?.contains("provider.usage") == true else {return}
            while !Task.isCancelled {
                await model.refreshUsage()
                do {try await Task.sleep(for: .seconds(60))} catch {return}
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $model.showNewProject) {NewProjectSheet()}
        .sheet(isPresented: $model.showNewSpace) {NewSidebarSpaceSheet()}
        .sheet(isPresented: $model.showNewWorkspace) {NewWorkspaceSheet()}
        .sheet(item: $model.newFixedTabKind) {kind in NewFixedTabSheet(kind: kind.id, project: kind.projectId)}
        .alert("操作を完了できませんでした", isPresented: Binding(get: {model.error != nil}, set: {if !$0 {model.error = nil}})) {Button("閉じる") {model.error = nil}} message: {Text(model.error ?? "")}
    }
}
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsedProjects") ?? [])
    @State private var setupProject: Project?
    @State private var removingProject: Project?
    @State private var projectDropSelection = SidebarProjectDropSelection()
    private var deleting: Workspace? {
        get {model.pendingWorkspaceDeletion}
        nonmutating set {model.pendingWorkspaceDeletion = newValue}
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swipeTranslation: CGFloat = 0
    @State private var sidebarWidth: CGFloat = 260
    @State private var settling = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Which Space this is.
            HStack(spacing: 6) {
                SidebarSpaceName(space: model.sidebarSpaces.active).id(model.sidebarSpaces.active.id)
                Spacer(minLength: 4)
                Menu {
                    ForEach(model.sidebarSpaces.spaces) {space in
                        Button(space.name) {switchSpace(space.id)}
                    }
                    Divider()
                    Button("新しいWorkspace…") {model.showNewSpace = true}
                } label: {Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(width: 22, height: 22)}
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Workspaceを切り替える").accessibilityLabel("Workspaceを切り替える")
            }
            .padding(.leading, SidebarMetrics.gutter + SidebarMetrics.inset).padding(.trailing, SidebarMetrics.gutter + 2)
            .padding(.top, 14).padding(.bottom, SidebarMetrics.sectionSpacing - 6)
            // 2. Tabs that are always here: everywhere first, then this Space's.
            SidebarFixedTabs()
                // Pages pinned to a project by earlier versions move under that project.
                .task(id: model.state.projects.map(\.id)) {FixedTabs.shared.adoptPins(projectIds: model.state.projects.map(\.id))}
            // 3. Where the work is. Project names are their own headings; adding a project is
            // rare and lives in the "+" menu at the bottom.
            GeometryReader {geometry in
                ZStack {
                    ForEach(pagerSpaces) {space in
                        projectList(space)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .offset(x: reduceMotion ? 0 : pageOffset(space.id, width: geometry.size.width) + swipeTranslation)
                            .opacity(reduceMotion && space.id != model.sidebarSpaces.active.id ? 0 : 1)
                            .allowsHitTesting(space.id == model.sidebarSpaces.active.id && swipeTranslation == 0 && !settling)
                            .accessibilityHidden(space.id != model.sidebarSpaces.active.id)
                    }
                }.clipped()
                    .onAppear {sidebarWidth = geometry.size.width}
                    .onChange(of: geometry.size.width) {_, width in sidebarWidth = width}
            }
            // 4. Moving between Spaces.
            HStack(spacing: 6) {
                Button {step(-1)} label: {Image(systemName: "chevron.left").frame(width: 22, height: 28)}
                    .disabled(model.sidebarSpaces.adjacent(-1) == nil).help("前のWorkspace（⌥⌘←）")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.sidebarSpaces.spaces) {space in
                            SidebarSpaceButton(space: space, isSelected: space.id == model.sidebarSpaces.active.id) {
                                switchSpace(space.id)
                            }
                            .draggable(SidebarSpaceDrag(id: space.id))
                            .dropDestination(for: SidebarSpaceDrag.self) {items, _ in
                                guard !settling, swipeTranslation == 0, let item = items.first,
                                      model.sidebarSpaces.spaces.contains(where: {$0.id == item.id}) else {return false}
                                model.sidebarSpaces.move(item.id, to: space.id)
                                return true
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                Button {step(1)} label: {Image(systemName: "chevron.right").frame(width: 22, height: 28)}
                    .disabled(model.sidebarSpaces.adjacent(1) == nil).help("次のWorkspace（⌥⌘→）")
                Menu {
                    addProjectButtons
                    Divider()
                    Button("新しいWorkspace…") {model.showNewSpace = true}
                } label: {Image(systemName: "plus").foregroundStyle(.tertiary).frame(width: 24, height: 28)}
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("プロジェクトやWorkspaceを追加").accessibilityLabel("プロジェクトやWorkspaceを追加")
            }.buttonStyle(.plain).foregroundStyle(.tertiary).padding(.horizontal, SidebarMetrics.gutter).padding(.vertical, 6)
        }.background(Palette.sidebar).clipped()
        .background(SidebarSwipeArea(canBegin: {!settling}, onProgress: {translation in
            guard !settling else {return}
            let offset = translation < 0 ? 1 : -1
            swipeTranslation = SidebarSwipeGesture.resistedTranslation(translation, width: sidebarWidth,
                canNavigate: model.sidebarSpaces.adjacent(offset) != nil)
        }, onEnd: finishSwipe))
        .onChange(of: model.sidebarSpaces.active.id) {_, _ in
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {swipeTranslation = 0; settling = false}
        }
        .sheet(item: $setupProject) {project in WorktreeSetupSheet(project: project)}
        .alert("neuraOSからプロジェクトを削除しますか？", isPresented: Binding(get: {removingProject != nil}, set: {if !$0 {removingProject = nil}}), presenting: removingProject) {project in
            Button("キャンセル", role: .cancel) {removingProject = nil}
            Button("neuraOSから削除", role: .destructive) {
                removingProject = nil
                let workspaces = model.state.workspaces.filter {$0.projectId == project.id}
                guard !workspaces.contains(where: {DraftCache.shared.load($0.id).values.contains(where: {$0.dirty})}) else {
                    model.error = "未保存の編集があります。保存または破棄してから削除してください。"
                    return
                }
                Task {await model.removeProject(project)}
            }
        } message: {project in
            Text("「\(project.name)」と配下の作業をneuraOSの一覧から削除します。フォルダ・ファイル・worktree・ブランチはそのまま残ります。実行中のターミナルとエージェントは終了します。")
        }
        .alert("変更を破棄してworktreeを削除しますか？", isPresented: Binding(get: {deleting != nil}, set: {if !$0 {deleting = nil}}), presenting: deleting) {workspace in
            Button("キャンセル", role: .cancel) {deleting = nil}
            if model.state.features?.contains("workspace.delete.discard") == true {
                Button("変更・未追跡ファイルも含めて削除", role: .destructive) {deleting = nil; deleteWorkspace(workspace, discardChanges: true)}
            }
        } message: {workspace in
            Text("「\(workspace.name)」には未コミットの変更、未追跡ファイル、または.envなどの無視対象ファイルがあります。削除すると元に戻せません。ターミナルとエージェントはまとめて終了します。ブランチは残ります。")
        }
    }
    @ViewBuilder private var addProjectButtons: some View {
        Button("新しいプロジェクト…") {model.showNewProject = true}
            .disabled(!model.connected || !model.supportsFolderless || model.isBusy("project.create"))
        Button("フォルダを開く…") {model.addProject()}
    }
    private func deleteWorkspace(_ workspace: Workspace, discardChanges: Bool = false) {
        guard !DraftCache.shared.load(workspace.id).values.contains(where: {$0.dirty}) else {
            model.error = "未保存の編集があります。保存または破棄してから削除してください。"
            return
        }
        Task {await model.deleteWorkspace(workspace, discardChanges: discardChanges)}
    }
    private var pagerSpaces: [SidebarSpace] {
        let spaces = model.sidebarSpaces.spaces
        let index = spaces.firstIndex(where: {$0.id == model.sidebarSpaces.active.id}) ?? 0
        return spaces.enumerated().filter {abs($0.offset - index) <= 1}.map(\.element)
    }
    private func pageOffset(_ id: String, width: CGFloat) -> CGFloat {
        let spaces = model.sidebarSpaces.spaces
        let index = spaces.firstIndex(where: {$0.id == id}) ?? 0
        let active = spaces.firstIndex(where: {$0.id == model.sidebarSpaces.active.id}) ?? 0
        return CGFloat(index - active) * width
    }
    @ViewBuilder
    private func projectActions(_ project: Project, space: SidebarSpace) -> some View {
        if project.supportsGit {
            Button("新しいworktree…") {
                if let workspace = model.state.workspaces.first(where: {$0.projectId == project.id}) {
                    model.select(workspace.id)
                }
                model.showNewWorkspace = true
            }
            Divider()
        }
        if project.folderless == true {
            Button("フォルダを紐づける…") {model.attachFolder(to: project)}
                .disabled(!model.connected || model.isBusy("project.attach.\(project.id)") || !model.supportsFolderless)
        }
        if project.supportsGit {
            Button("setup scriptを設定…") {setupProject = project}
                .disabled(!model.connected || model.state.features?.contains("project.worktree-setup") != true)
            Menu("worktree作成時に自動起動") {
                ForEach(["codex", "claude", "shell"], id: \.self) {provider in
                    Toggle(provider == "codex" ? "Codex" : provider == "claude" ? "Claude Code" : "Terminal",
                           isOn: Binding(get: {project.worktreeStartup?.contains(provider) == true},
                                         set: {enabled in Task {await model.setWorktreeStartup(project, provider: provider, enabled: enabled)}}))
                }
            }
            .disabled(!model.connected || model.isBusy("project.settings.\(project.id)") || model.state.features?.contains("project.worktree-startup") != true)
            Divider()
        }
        Menu("既定のAI") {
            Picker("会話", selection: Binding(get: {project.conversationProvider},
                set: {provider in Task {await model.setDefaultProvider(project, provider: provider, delegation: false)}})) {
                Text("Codex").tag("codex")
                Text("Claude Code").tag("claude")
            }
            Picker("委任", selection: Binding(get: {project.delegationProvider},
                set: {provider in Task {await model.setDefaultProvider(project, provider: provider, delegation: true)}})) {
                Text("Codex").tag("codex")
                Text("Claude Code").tag("claude")
            }
        }
        .disabled(!model.connected || model.isBusy("project.settings.\(project.id)") || model.state.features?.contains("project.default-providers") != true)
        Divider()
        Menu("Workspaceへ移動") {
            ForEach(model.sidebarSpaces.spaces.filter {$0.id != space.id}) {space in
                Button(space.name) {model.moveProject(project.id, to: space.id)}
            }
        }.disabled(model.sidebarSpaces.spaces.count < 2)
        Button("固定タブを追加…") {model.newFixedTabKind = FixedTabKind(id: "browser", projectId: project.id)}
        Divider()
        Button("neuraOSから削除…", role: .destructive) {removingProject = project}
            .disabled(!model.connected || model.isBusy("project.remove.\(project.id)") || model.state.features?.contains("project.remove") != true)
    }
    private func projectList(_ space: SidebarSpace) -> some View {
        let projects = model.sidebarSpaces.projects(in: space.id, from: model.state.projects)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                ForEach(Array(projects.enumerated()), id: \.element.id) {index, project in
                    let next = projects.dropFirst(index + 1).first?.id
                    VStack(alignment: .leading, spacing: SidebarMetrics.rowSpacing) {
                        projectRow(project, space: space)
                        if !collapsed.contains(project.id) {
                            SidebarProjectFixedTabs(projectId: project.id)
                            ForEach(model.state.workspaces.filter {$0.projectId == project.id}) {workspace in
                                workspaceRow(workspace, space: space)
                            }
                        }
                    }
                    .modifier(SidebarProjectDropTarget(
                        before: SidebarProjectBoundary(spaceId: space.id, beforeProjectId: project.id),
                        after: SidebarProjectBoundary(spaceId: space.id, beforeProjectId: next),
                        selection: $projectDropSelection, spacing: SidebarMetrics.rowSpacing
                    ) {providers, boundary in
                        dropProject(providers, before: boundary.beforeProjectId, in: space)
                    })
                }
                if !projects.isEmpty {
                    Color.clear.frame(height: 48)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                        .contextMenu {addProjectButtons}
                        .modifier(SidebarProjectDropTarget(
                            before: SidebarProjectBoundary(spaceId: space.id, beforeProjectId: nil),
                            after: SidebarProjectBoundary(spaceId: space.id, beforeProjectId: nil),
                            selection: $projectDropSelection, spacing: SidebarMetrics.rowSpacing
                        ) {providers, _ in
                            dropProject(providers, before: nil, in: space)
                        })
                } else {
                    VStack(spacing: 10) {
                        Text("プロジェクトを作成して始める").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("新しいプロジェクト…") {model.showNewProject = true}.disabled(!model.connected || !model.supportsFolderless || model.isBusy("project.create"))
                        Button("フォルダを開く…") {model.addProject()}
                    }.frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }.padding(.horizontal, SidebarMetrics.gutter).padding(.top, SidebarMetrics.sectionSpacing - 10)
        }
        .onChange(of: model.sidebarSpaces.active.id) {_, _ in projectDropSelection = SidebarProjectDropSelection()}
        .onChange(of: projects.map(\.id)) {_, _ in projectDropSelection = SidebarProjectDropSelection()}
    }
    private func workspaceRow(_ workspace: Workspace, space: SidebarSpace) -> some View {
        // A fixed tab on screen leaves the worktree underneath marked, but not as the front item.
        let chosen = model.selectedId == workspace.id
        let front = model.frontId == workspace.id
        return Button {model.select(workspace.id)} label: {
            HStack(spacing: 10) {
                Image(systemName: workspace.kind == "worktree" ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 12)).foregroundStyle(front ? Color.accentColor : Color.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.system(size: 13, weight: front ? .medium : .regular))
                        .foregroundStyle(.primary).lineLimit(1)
                    if let job = model.deletion(workspace.id) {
                        Text(job.label).font(.caption2).foregroundStyle(job.status == "failed" ? Color.orange : Color.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let job = model.deletion(workspace.id) {
                    if job.inProgress {ProgressView().controlSize(.mini)}
                    else if job.status == "failed" {Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)}
                } else {
                    WorkspaceChecksIndicator(workspace: workspace, visible: space.id == model.sidebarSpaces.active.id)
                    WorkspaceActivityStatus(workspaceId: workspace.id)
                }
            }
            .padding(.horizontal, SidebarMetrics.inset).frame(minHeight: SidebarMetrics.rowHeight)
            .modifier(SidebarRowStyle(selected: front, marked: chosen && !front))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(workspace.name).accessibilityAddTraits(front ? .isSelected : [])
        .contextMenu {
            if workspace.kind == "root" {
                Button {
                    if DraftCache.shared.load(workspace.id).values.contains(where: {$0.dirty}) {
                        model.error = "未保存の編集があります。保存または破棄してから更新してください。"
                    } else {Task {await model.syncDefault(workspace)}}
                } label: {
                    Label("リモートの最新に更新", systemImage: "arrow.down.circle")
                }
                    .help("originのデフォルトブランチに切り替えて更新します。変更や実行中のターミナルがある場合は停止します。")
                    .disabled(model.isBusy(workspace.id) || !model.connected || model.state.features?.contains("workspace.remote-default") != true)
            }
            if workspace.kind == "worktree" {
                Button("worktreeを削除", role: .destructive) {
                    deleteWorkspace(workspace)
                }.disabled(model.isBusy(workspace.id) || !model.connected || (!model.supportsDeletionJobs && model.state.features?.contains("workspace.delete") != true))
            }
        }
    }
    private func toggleCollapsed(_ id: String) {
        if collapsed.contains(id) {collapsed.remove(id)} else {collapsed.insert(id)}
        UserDefaults.standard.set(Array(collapsed), forKey: "sidebar.collapsedProjects")
    }
    private func projectRow(_ project: Project, space: SidebarSpace) -> some View {
        let folded = collapsed.contains(project.id)
        return HoverReveal {hovered in
            HStack(spacing: 4) {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    .opacity(hovered || folded ? 1 : 0)
                Spacer(minLength: 4)
                if folded {SidebarProjectActivity(projectId: project.id)}
                if project.supportsGit {
                    Button {
                        if let workspace = model.state.workspaces.first(where: {$0.projectId == project.id}) {
                            model.select(workspace.id)
                        }
                        model.showNewWorkspace = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("新しいworktree（⌘N）").accessibilityLabel("\(project.name)に新しいworktree")
                    .opacity(hovered ? 1 : 0)
                }
            }
            .padding(.leading, SidebarMetrics.inset).padding(.trailing, 2)
            .frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture {toggleCollapsed(project.id)}
        }
        .padding(.top, 10)
        .onDrag {
            SidebarProjectDrag(projectId: project.id, spaceId: space.id).provider
        } preview: {
            Label(project.name, systemImage: "folder")
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .help("クリックで折りたたみ、ドラッグで並び替え、右クリックで設定")
        .accessibilityLabel("\(project.name)、\(folded ? "折りたたみ中" : "展開中")")
        .accessibilityAddTraits(.isButton)
        .contextMenu {projectActions(project, space: space)}
    }

    private func dropProject(_ providers: [NSItemProvider], before targetId: String?, in space: SidebarSpace) -> Bool {
        guard space.id == model.sidebarSpaces.active.id,
              let provider = providers.first(where: {$0.hasItemConformingToTypeIdentifier(SidebarProjectDrag.typeIdentifier)}) else {return false}
        provider.loadDataRepresentation(forTypeIdentifier: SidebarProjectDrag.typeIdentifier) {data, _ in
            guard let data, let drag = try? JSONDecoder().decode(SidebarProjectDrag.self, from: data),
                  drag.spaceId == space.id else {return}
            Task { @MainActor in
                guard model.sidebarSpaces.active.id == space.id else {return}
                _ = model.sidebarSpaces.insertProject(drag.projectId, before: targetId,
                                                       in: space.id, projects: model.state.projects)
            }
        }
        return true
    }

    private func finishSwipe(_ offset: Int?) {
        guard !settling else {return}
        let target = offset.flatMap {model.sidebarSpaces.adjacent($0)}
        settle(to: target, offset: offset ?? 0)
    }
    private func settle(to id: String?, offset: Int) {
        settling = true
        let origin = model.sidebarSpaces.active.id
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.3, bounce: 0), completionCriteria: .removed) {
            swipeTranslation = id == nil ? 0 : -CGFloat(offset) * sidebarWidth
        } completion: {
            guard model.sidebarSpaces.active.id == origin else {return}
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let id {model.switchSpace(id)}
                swipeTranslation = 0
                settling = false
            }
        }
    }
    private func step(_ offset: Int) {
        if let id = model.sidebarSpaces.adjacent(offset) {switchSpace(id)}
    }
    private func switchSpace(_ id: String) {
        guard !settling, id != model.sidebarSpaces.active.id else {return}
        let spaces = model.sidebarSpaces.spaces
        let offset = (spaces.firstIndex(where: {$0.id == id}) ?? 0) - (spaces.firstIndex(where: {$0.id == model.sidebarSpaces.active.id}) ?? 0)
        if abs(offset) == 1 {settle(to: id, offset: offset)}
        else {model.switchSpace(id)}
    }
}
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("次の作業を、ここから。").font(.system(size: 24, weight: .medium))
            Text("Codexへの相談も、ブラウザでの調べものも。フォルダなしで始められます。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("新しいプロジェクト…") {model.showNewProject = true}.controlSize(.large).padding(.top, 6)
                .disabled(!model.connected || !model.supportsFolderless || model.isBusy("project.create"))
            Button("フォルダを開く…") {model.addProject()}
            Text("⌘ O").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct NewProjectSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新しいプロジェクト").font(.system(size: 20, weight: .semibold))
            Text("会話やブラウザをまとめる場所です。フォルダは後から紐づけられます。").foregroundStyle(.secondary)
            TextField("プロジェクト名", text: $name)
            HStack {
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction).disabled(model.isBusy("project.create"))
                Spacer()
                if model.isBusy("project.create") {ProgressView().controlSize(.small)}
                Button("作成") {Task {await model.createProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines))}}
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy("project.create") || !model.connected || !model.supportsFolderless || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }
        }.padding(28).frame(width: 420).interactiveDismissDisabled(model.isBusy("project.create"))
    }
}
