import SwiftUI

struct WorkspaceChecksSnapshot: Decodable {
    struct Check: Decodable {let name: String; let state: String}
    let state: String
    let checks: [Check]
    let head: String?
    let fetchedAt: String
    let message: String?
    var label: String {
        switch state {
        case "running": return "CI 実行中"
        case "success": return "CI 成功"
        case "failure": return "CI 失敗・対応が必要"
        case "cancelled": return "CI キャンセル"
        case "none": return "CI なし"
        case "unpublished": return "GitHubに未反映のコミット"
        case "unavailable": return "CI 取得不可"
        default: return "CI 状態不明"
        }
    }
    var help: String {
        var lines: [String] = [label]
        if let head {lines.append("コミット: \(head.prefix(7))")}
        for check in checks {lines.append("\(check.name): \(check.state)")}
        if let message {lines.append(message)}
        lines.append("表示中は選択状態に応じて自動更新")
        return lines.joined(separator: "\n")
    }
}

struct WorkspaceChecksIndicator: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let workspace: Workspace
    var visible = true
    @State private var snapshot: WorkspaceChecksSnapshot?
    @State private var failed = false
    @State private var generation = 0
    private var selected: Bool {model.selectedId == workspace.id}
    private var enabled: Bool {visible && scenePhase == .active && workspace.supportsGit && model.connected && model.state.features?.contains("github.checks") == true}
    private var showsBadge: Bool {failed || snapshot.map {!["none", "unpublished", "unsupported"].contains($0.state)} == true}
    private var state: String {(!model.connected || failed) ? "unavailable" : snapshot?.state ?? "unknown"}
    var body: some View {
        Group {
            if showsBadge {
                WorkspaceChecksBadge(state: state,
                    help: (!model.connected || failed) ? "CIを取得できません。接続を確認しています。" : snapshot?.help ?? "CI 状態不明",
                    label: (!model.connected || failed) ? "CI 取得不可" : snapshot?.label ?? "CI 状態不明")
            }
        }
        .onReceive(model.githubUpdated) {id in if id == workspace.id {generation += 1}}
        .task(id: "\(workspace.id):\(enabled):\(selected):\(generation)") {
            guard enabled else {return}
            var failures = 0
            while !Task.isCancelled {
                do {
                    let next: WorkspaceChecksSnapshot = try await model.api.get("v1/workspaces/\(workspace.id)/checks")
                    guard !Task.isCancelled else {return}
                    snapshot = next; failed = false
                    failures = next.state == "unavailable" ? failures + 1 : 0
                } catch {
                    guard !Task.isCancelled else {return}
                    failed = true; failures += 1
                }
                do {try await Task.sleep(for: .seconds(failures > 0 ? GitHubRefreshPolicy.retryDelay(failures: failures) : selected ? 60 : 120))} catch {return}
            }
        }
    }
}

struct WorkspaceChecksBadge: View {
    let state: String
    let help: String
    let label: String
    private var symbol: String {
        switch state {
        case "running": return "clock.arrow.circlepath"
        case "success": return "checkmark.seal.fill"
        case "failure": return "xmark.seal.fill"
        case "cancelled": return "minus.circle"
        default: return "questionmark.diamond"
        }
    }
    private var color: Color {
        switch state {
        case "running": return .orange
        case "success": return .green
        case "failure": return .red
        default: return .secondary
        }
    }
    var body: some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            .frame(width: 14, height: 16).help(help).accessibilityLabel(label)
    }
}
