import SwiftUI
import AppKit
import ChromiumBridge

extension AppModel {
    var commandBarVisible: Bool {CommandBarPanel.shared.isVisible}

    func sendWorkspaceCommand(_ action: WorkspaceAction) {
        // Capture the destination now; mounted background workspaces must never handle it.
        guard let workspace = selected, !showNewSpace, !showNewWorkspace, !showNewProject,
              NSApp.modalWindow == nil else {return}
        if commandBarVisible {
            // While the command bar is up, only asking for it again (to switch its mode) passes.
            guard case .commandBar = action else {return}
        } else {
            guard WorkspaceCommandContext.allowsCommands(in: NSApp.keyWindow) else {return}
        }
        workspaceCommands.send(WorkspaceCommandRequest(workspaceId: workspace.id, action: action))
    }

    /// Browser tabs of every worktree, read from each workspace's saved tab strip.
    func browserTabs(defaults: UserDefaults = .standard) -> [CommandBarTab] {
        state.workspaces.flatMap {workspace -> [CommandBarTab] in
            guard let data = defaults.data(forKey: "workspaceTabs.\(workspace.id)"),
                  let layout = try? JSONDecoder().decode(WorkspaceTabState.self, from: data) else {return []}
            let project = state.projects.first {$0.id == workspace.projectId}?.name ?? ""
            return layout.tabs.filter {$0.kind == "browser"}.compactMap {tab in
                guard let url = tab.browserURL ?? defaults.string(forKey: "browser.\(workspace.id).\(tab.id)"), !url.isEmpty else {return nil}
                return CommandBarTab(workspaceId: workspace.id, workspaceName: project.isEmpty ? workspace.name : "\(project) / \(workspace.name)",
                                     tabId: tab.id, title: tab.browserTitle ?? "", url: url)
            }
        }
    }
}

enum WorkspaceCommandContext {
    static func allowsCommands(in window: NSWindow?) -> Bool {
        guard let window else {return false}
        return window.sheetParent == nil && window.attachedSheet == nil
    }
}

/// What a shortcut does when it is routed directly instead of through the menu bar.
enum AppShortcut: Equatable {
    case workspace(WorkspaceAction)
    case conversation
    case newWork, newSpace, newProject, openFolder
    case space(Int)
    case toggleSidebar, toggleInspector

    /// The shortcut for a key press. `key` is the unshifted, lower-case character.
    /// These mirror the key equivalents shown in the menu bar.
    static func match(key: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> AppShortcut? {
        let modifiers = flags.intersection([.command, .shift, .option, .control])
        guard modifiers.contains(.command) else {return nil}
        let split = key == "\\" || key == "¥"
        switch modifiers {
        case .command:
            if let number = Int(key), (1...9).contains(number) {return .workspace(.select(number))}
            if split {return .workspace(.toggleSplit)}
            switch key {
            case "t": return .workspace(.commandBar(edit: false))
            case "l": return .workspace(.commandBar(edit: true))
            case "r": return .workspace(.browser(.reload))
            case ".": return .workspace(.browser(.stop))
            case "[": return .workspace(.browser(.back))
            case "]": return .workspace(.browser(.forward))
            case "f": return .workspace(.browser(.find))
            case "g": return .workspace(.browser(.findNext))
            case "=", "+", ";": return .workspace(.browser(.zoomIn))
            case "-": return .workspace(.browser(.zoomOut))
            case "0": return .workspace(.browser(.zoomReset))
            case "d": return .workspace(.browser(.togglePin))
            case "n": return .newWork
            case "o": return .openFolder
            default: return nil
            }
        case [.command, .shift]:
            switch key {
            case "t": return .conversation
            case "b": return .workspace(.add("browser"))
            case "[": return .workspace(.move(-1))
            case "]": return .workspace(.move(1))
            case "r": return .workspace(.browser(.hardReload))
            case "c": return .workspace(.browser(.copyURL))
            case "e": return .workspace(.inspector("files"))
            case "g": return .workspace(.inspector("git"))
            case "n": return .newSpace
            default: return nil
            }
        case [.command, .option]:
            if split {return .toggleInspector}
            if keyCode == 123 {return .space(-1)}
            if keyCode == 124 {return .space(1)}
            switch key {
            case "t": return .workspace(.add("claude"))
            case "i": return .workspace(.browser(.devTools))
            case "g": return .workspace(.inspector("github"))
            case "n": return .newProject
            default: return nil
            }
        case [.command, .control]:
            switch key {
            case "t": return .workspace(.add("shell"))
            case "s": return .toggleSidebar
            default: return nil
            }
        default: return nil
        }
    }
}

extension AppModel {
    /// Runs a shortcut under the same conditions as its menu item. False leaves the key to the page.
    func perform(_ shortcut: AppShortcut) -> Bool {
        let dialog = showNewSpace || showNewWorkspace || showNewProject
        switch shortcut {
        case .workspace(let action):
            guard let workspace = selected, !dialog else {return false}
            switch action {
            case .browser: guard activeTabKind == "browser" else {return false}
            case .toggleSplit: guard activeTabKind != nil else {return false}
            case .inspector(let pane): guard pane == "files" ? workspace.hasFolder : workspace.supportsGit else {return false}
            default: break
            }
            sendWorkspaceCommand(action)
        case .conversation:
            guard let workspace = selected, !dialog else {return false}
            sendWorkspaceCommand(.add(conversationProvider(for: workspace)))
        case .newWork:
            guard !gitProjects.isEmpty else {return false}
            showNewWorkspace = true
        case .newSpace: showNewSpace = true
        case .newProject:
            guard connected, supportsFolderless else {return false}
            showNewProject = true
        case .openFolder: addProject()
        case .space(let offset):
            guard let id = sidebarSpaces.adjacent(offset) else {return false}
            switchSpace(id)
        case .toggleSidebar: showSidebar.toggle()
        case .toggleInspector:
            guard selected != nil else {return false}
            showInspector.toggle()
        }
        return true
    }
}

/// Keys that must work whichever view has focus.
///
/// ⌘W closes the current tab and ⌃Tab walks recently used tabs until Control is released.
/// While a web page has keyboard focus SwiftUI leaves its menu commands without an action,
/// so every application shortcut is matched and run here instead of through the menu bar.
@MainActor enum KeyboardRouter {
    private static var monitor: Any?

    enum Route: Equatable {case close, recent(Int), finishRecent}

    static func route(type: NSEvent.EventType, keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, hasActiveTab: Bool) -> Route? {
        let modifiers = flags.intersection([.command, .shift, .option, .control])
        if type == .flagsChanged {return modifiers.contains(.control) ? nil : .finishRecent}
        guard type == .keyDown else {return nil}
        if modifiers == .command, characters?.lowercased() == "w" {return hasActiveTab ? .close : nil}
        if keyCode == 48, modifiers == .control {return .recent(1)}
        if keyCode == 48, modifiers == [.control, .shift] {return .recent(-1)}
        return nil
    }

    /// True when the key window's first responder is inside a Chromium page.
    static func pageHasFocus(in window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is NCChromiumView {return true}
            view = current.superview
        }
        return false
    }

    static func install(_ model: AppModel) {
        guard monitor == nil else {return}
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {event in
            let type = event.type, keyCode = event.keyCode, flags = event.modifierFlags
            let characters = type == .keyDown ? event.charactersIgnoringModifiers : nil
            let plain = type == .keyDown ? (event.characters(byApplyingModifiers: []) ?? characters ?? "").lowercased() : ""
            let window = event.window
            let handled = MainActor.assumeIsolated {() -> Bool in
                let route = route(type: type, keyCode: keyCode, characters: characters, flags: flags, hasActiveTab: model.activeTabKind != nil)
                if route == .finishRecent {
                    if let workspaceId = model.selectedId {
                        model.workspaceCommands.send(WorkspaceCommandRequest(workspaceId: workspaceId, action: .finishRecent))
                    }
                    return false
                }
                // Only the main window owns tabs; extension, DevTools and settings windows keep their own keys.
                guard type == .keyDown, window?.identifier?.rawValue.hasPrefix("main") == true,
                      WorkspaceCommandContext.allowsCommands(in: window), !model.commandBarVisible else {return false}
                switch route {
                case .close: model.sendWorkspaceCommand(.close); return true
                case .recent(let offset): model.sendWorkspaceCommand(.recent(offset)); return true
                case .finishRecent, nil: break
                }
                guard pageHasFocus(in: window), let shortcut = AppShortcut.match(key: plain, keyCode: keyCode, flags: flags) else {return false}
                return model.perform(shortcut)
            }
            return handled ? nil : event
        }
    }
}

struct WorkspaceCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("タブ") {
            Group {
                Button("新しいタブ（検索・URL・Terminal）") {send(.commandBar(edit: false))}.keyboardShortcut("t")
                Button("アドレスを入力") {send(.commandBar(edit: true))}.keyboardShortcut("l")
                Divider()
                Button("新しいTerminal") {send(.add("shell"))}.keyboardShortcut("t", modifiers: [.command, .control])
                Button("新しい会話") {if let workspace = model.selected {send(.add(model.conversationProvider(for: workspace)))}}.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("新しいCodex") {send(.add("codex"))}
                Button("新しいClaude Code") {send(.add("claude"))}.keyboardShortcut("t", modifiers: [.command, .option])
                Button("新しいBrowser") {send(.add("browser"))}.keyboardShortcut("b", modifiers: [.command, .shift])
            }
            .disabled(model.selected == nil || model.showNewSpace || model.showNewWorkspace || model.showNewProject)
            Group {
                Divider()
                // ⌘W itself is delivered by KeyboardRouter so it also works inside a page or terminal.
                Button("タブを閉じる（⌘W）") {send(.close)}.disabled(model.activeTabKind == nil)
                Button(model.activeTabKind == nil ? "右に並べて表示" : "右に並べて表示／分割を解除") {send(.toggleSplit)}
                    .keyboardShortcut("\\").disabled(model.activeTabKind == nil)
            }
            .disabled(model.selected == nil || model.showNewSpace || model.showNewWorkspace || model.showNewProject)
            Group {
                Divider()
                Button("前のタブ") {send(.move(-1))}.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("次のタブ") {send(.move(1))}.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("直前に使ったタブ（⌃Tab）") {send(.recent(1)); send(.finishRecent)}
                ForEach(1...9, id: \.self) {number in
                    Button(number == 9 ? "最後のタブ" : "タブ\(number)を選択") {send(.select(number))}
                        .keyboardShortcut(KeyEquivalent(Character(String(number))))
                }
            }
            .disabled(model.selected == nil || model.showNewSpace || model.showNewWorkspace || model.showNewProject)
        }
        CommandMenu("ブラウザ") {
            Group {
                Button("再読み込み") {browser(.reload)}.keyboardShortcut("r")
                Button("キャッシュを使わず再読み込み") {browser(.hardReload)}.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("読み込みを停止") {browser(.stop)}.keyboardShortcut(".")
                Button("戻る") {browser(.back)}.keyboardShortcut("[")
                Button("進む") {browser(.forward)}.keyboardShortcut("]")
                Divider()
                Button("ページ内を検索…") {browser(.find)}.keyboardShortcut("f")
                Button("次を検索") {browser(.findNext)}.keyboardShortcut("g")
                Button("前を検索（検索欄で⇧⏎）") {browser(.findPrevious)}
                Divider()
                Button("拡大") {browser(.zoomIn)}.keyboardShortcut("=")
                Button("縮小") {browser(.zoomOut)}.keyboardShortcut("-")
                Button("実際のサイズ") {browser(.zoomReset)}.keyboardShortcut("0")
            }
            .disabled(!browserActive)
            Group {
                Divider()
                Button("URLをコピー") {browser(.copyURL)}.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("ピン留め／解除") {browser(.togglePin)}.keyboardShortcut("d")
                Button("デフォルトのブラウザで開く") {browser(.openExternally)}
                Button("開発者ツール") {browser(.devTools)}.keyboardShortcut("i", modifiers: [.command, .option])
            }
            .disabled(!browserActive)
            Divider()
            Toggle("会話内のリンクを右に並べて開く", isOn: Binding(get: {model.splitAgentLinks}, set: {model.splitAgentLinks = $0}))
        }
        CommandMenu("サイドバー") {
            Group {
                Button("エクスプローラーを表示") {send(.inspector("files"))}
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.selected?.hasFolder != true)
                Button("Gitを表示") {send(.inspector("git"))}
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.selected?.supportsGit != true)
                Button("GitHubを表示") {send(.inspector("github"))}
                    .keyboardShortcut("g", modifiers: [.command, .option]).disabled(model.selected?.supportsGit != true)
            }
            .disabled(model.selected == nil || model.showNewSpace || model.showNewWorkspace || model.showNewProject)
        }
    }

    private var browserActive: Bool {
        model.selected != nil && model.activeTabKind == "browser" && !model.showNewSpace && !model.showNewWorkspace && !model.showNewProject
    }
    private func send(_ action: WorkspaceAction) {model.sendWorkspaceCommand(action)}
    private func browser(_ command: BrowserCommand) {model.sendWorkspaceCommand(.browser(command))}
}
