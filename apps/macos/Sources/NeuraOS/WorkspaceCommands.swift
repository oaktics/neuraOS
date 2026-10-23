import SwiftUI
import AppKit

enum WorkspaceAction: Equatable {
    case add(String), close, move(Int), select(Int), inspector(String)
}

struct WorkspaceCommandRequest {
    let workspaceId: String
    let action: WorkspaceAction
}

extension AppModel {
    func sendWorkspaceCommand(_ action: WorkspaceAction) {
        // Capture the destination now; mounted background workspaces must never handle it.
        guard let workspace = selected, !showNewSpace, !showNewWorkspace,
              NSApp.keyWindow?.attachedSheet == nil else {return}
        workspaceCommands.send(WorkspaceCommandRequest(workspaceId: workspace.id, action: action))
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("タブ") {
            Group {
                Button("新しいTerminal") {send(.add("shell"))}.keyboardShortcut("t")
                Button("新しいCodex") {send(.add("codex"))}.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("新しいClaude Code") {send(.add("claude"))}.keyboardShortcut("t", modifiers: [.command, .option])
                Button("新しいBrowser") {send(.add("browser"))}.keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("現在のタブを閉じる…") {send(.close)}
                    .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.busy)
                Divider()
                Button("前のタブ") {send(.move(-1))}.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("次のタブ") {send(.move(1))}.keyboardShortcut("]", modifiers: [.command, .shift])
                ForEach(1...9, id: \.self) {number in
                    Button(number == 9 ? "最後のタブ" : "タブ\(number)を選択") {send(.select(number))}
                        .keyboardShortcut(KeyEquivalent(Character(String(number))))
                }
            }
            .disabled(model.selected == nil || model.showNewSpace || model.showNewWorkspace)
        }
        CommandMenu("サイドバー") {
            Group {
                Button("エクスプローラーを表示") {send(.inspector("files"))}
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Gitを表示") {send(.inspector("git"))}
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.selected?.supportsGit != true)
                Button("GitHubを表示") {send(.inspector("github"))}
                    .keyboardShortcut("g", modifiers: [.command, .option]).disabled(model.selected?.supportsGit != true)
            }
            .disabled(model.selected == nil || model.showNewSpace || model.showNewWorkspace)
        }
    }

    private func send(_ action: WorkspaceAction) {model.sendWorkspaceCommand(action)}
}

extension WorkspaceTabState {
    mutating func moveSelection(by offset: Int) {
        guard !tabs.isEmpty else {return}
        guard let index = tabs.firstIndex(where: {$0.id == selectedId}) else {
            selectedId = offset < 0 ? tabs.last?.id : tabs.first?.id
            return
        }
        let next = ((index + offset) % tabs.count + tabs.count) % tabs.count
        selectedId = tabs[next].id
    }

    mutating func select(number: Int) {
        guard (1...9).contains(number) else {return}
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else {return}
        selectedId = tabs[index].id
    }
}
