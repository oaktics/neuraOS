import SwiftUI

struct GitHubSnapshot: Decodable {
    let repository: String; let branch: String; let head: String; let defaultBranch: String
    let mergeMethods: [String]; let fetchedAt: String; let pullRequest: GitHubPR?
    func target(workspaceId: String, type: String) -> [String: Any] {
        ["type": type, "workspaceId": workspaceId, "repository": repository, "branch": branch, "expectedHead": head]
    }
}
struct GitHubPR: Decodable {
    let number: Int; let title: String; let body: String; let url: String; let state: String; let isDraft: Bool
    let headRefName: String; let headRefOid: String; let baseRefName: String; let mergeStateStatus: String; let reviewDecision: String?
    let author: GitHubAuthor?; let additions: Int?; let deletions: Int?; let changedFiles: Int?; let files: [GitHubFile]?
    let unresolvedThreads: Int; let comments: [GitHubComment]; let checks: [GitHubCheck]
    var label: String {isDraft ? "Draft" : state == "OPEN" ? "Open" : state == "MERGED" ? "Merged" : "Closed"}
    var canMerge: Bool {state == "OPEN" && !isDraft && mergeStateStatus == "CLEAN" && reviewDecision != "CHANGES_REQUESTED" && unresolvedThreads == 0}
}
struct GitHubAuthor: Decodable {let login: String}
struct GitHubFile: Decodable, Identifiable {
    let path: String; let additions: Int; let deletions: Int
    var id: String {path}
}
struct GitHubComment: Decodable, Identifiable {
    let id: String; let kind: String; let body: String; let author: String; let url: String; let createdAt: String
    let path: String?; let line: Int?; let outdated: Bool; let state: String?
}
struct GitHubCheck: Decodable, Identifiable {
    let id: String; let name: String; let state: String; let url: String?
    var passed: Bool {["SUCCESS", "NEUTRAL", "SKIPPED"].contains(state)}
}
struct GitHubResult: Decodable {let ok: Bool; let message: String; let url: String?}
func methodLabel(_ method: String) -> String {method == "squash" ? "Squash" : method == "rebase" ? "Rebase" : "Merge commit"}

struct GitHubSidebar: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    let visible: Bool
    let openTerminal: () -> Void
    var body: some View {
        Group {
            if !workspace.supportsGit {
                Text("このフォルダではGitを使用していません。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            } else if model.supportsGitHub {
                GitHubPane(workspace: workspace, visible: visible, openTerminal: openTerminal)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.connected ? "GitHub 連携には Daemon の更新が必要です" : "Daemon への接続を確認しています…")
                        .font(.system(size: 12, weight: .medium))
                    Text("作業を保存してから Daemon を更新・再起動してください。再起動すると実行中のターミナルは終了します。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct GitHubPane: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    let visible: Bool
    let openTerminal: () -> Void
    @State private var snapshot: GitHubSnapshot?
    @State private var refreshing = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showCreate = false
    @State private var createSnapshot: GitHubSnapshot?
    @State private var showConfirmation = false
    @State private var confirmation = ""
    @State private var pending: [String: Any]?
    @State private var method = "squash"
    private var disabled: Bool {busy || refreshing || !model.connected || error != nil}
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot?.repository ?? "GitHub").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).help(snapshot?.repository ?? "GitHub")
                    Text(snapshot.map {"\($0.branch) · \($0.head.prefix(7))"} ?? "作業ブランチの PR とレビュー").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if refreshing || busy {ProgressView().controlSize(.small)}
                Button {Task {await refresh()}} label: {Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)}.buttonStyle(.plain).help("GitHubを更新").accessibilityLabel("GitHubを更新").disabled(refreshing || busy)
            }.padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice {Text(notice).foregroundStyle(.green).textSelection(.enabled)}
                    if let error {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("GitHub の状態を確認してください", systemImage: "exclamationmark.circle").fontWeight(.medium)
                            Text(error).textSelection(.enabled)
                            if snapshot != nil {Text("表示中の情報は前回の取得結果です。更新が成功するまで操作できません。").foregroundStyle(.secondary)}
                            Button("ターミナルを開く", action: openTerminal).disabled(model.busy)
                            Text("初回設定: brew install gh → gh auth login --hostname github.com → gh auth setup-git").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }.foregroundStyle(.orange)
                    }
                    if let snapshot {
                        VStack(alignment: .leading, spacing: 10) {
                            if let url = URL(string: "https://github.com/\(snapshot.repository)") {Link("リポジトリを開く ↗", destination: url)}
                            HStack {
                                Button("Push…") {confirmPush(snapshot)}.disabled(disabled)
                                if snapshot.pullRequest?.state != "OPEN" {Button("PR を作成…") {createSnapshot = snapshot; showCreate = true}.disabled(disabled)}
                            }.controlSize(.small)
                        }
                        Text("Push・PR に含まれるのはコミット済みの変更です。").font(.system(size: 11)).foregroundStyle(.secondary)
                        if let pr = snapshot.pullRequest {pullRequest(pr, snapshot: snapshot)}
                        else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("このブランチの PR はありません").font(.system(size: 14, weight: .medium))
                                Text("変更をコミットしたら、PR を作成してレビューへ進めます。").foregroundStyle(.secondary)
                            }.padding(.vertical, 12)
                        }
                        Text("更新 \(GitHubPresentation.relativeDate(snapshot.fetchedAt)) · 30秒ごとに自動更新").font(.system(size: 10)).foregroundStyle(.tertiary)
                    } else if error == nil {Text("GitHub に接続しています…").foregroundStyle(.secondary).padding(.vertical, 12)}
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: visible) {
            guard visible else {return}
            while !Task.isCancelled {
                if !busy && !showCreate && !showConfirmation {await refresh()}
                do {try await Task.sleep(for: .seconds(30))} catch {return}
            }
        }
        .sheet(isPresented: $showCreate) {
            if let snapshot = createSnapshot {
                GitHubCreateSheet(snapshot: snapshot, workspaceId: workspace.id) {command, push in
                    await perform(command, push: push)
                }
            }
        }
        .confirmationDialog(confirmation, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button(pending?["type"] as? String == "github.merge" ? "マージする" : "Push する") {
                if let pending {Task {_ = await perform(pending)}}
            }
            Button("キャンセル", role: .cancel) {pending = nil}
        }
    }
    private func pullRequest(_ pr: GitHubPR, snapshot: GitHubSnapshot) -> some View {
        GitHubPullRequestView(pr: pr, snapshot: snapshot, disabled: disabled, method: $method) {
            confirmMerge(snapshot, pr: pr)
        }.id("\(snapshot.repository)#\(pr.number)")
    }
    @MainActor private func refresh() async {
        guard model.supportsGitHub, !refreshing else {return}; refreshing = true; defer {refreshing = false}
        do {
            let value: GitHubSnapshot = try await model.api.get("v1/workspaces/\(workspace.id)/github")
            snapshot = value; error = nil
            if !value.mergeMethods.contains(method) {method = value.mergeMethods.first ?? "squash"}
        } catch is CancellationError {} catch {self.error = error.localizedDescription}
    }
    private func confirmPush(_ snapshot: GitHubSnapshot) {
        pending = snapshot.target(workspaceId: workspace.id, type: "github.push")
        confirmation = "\(snapshot.repository) の \(snapshot.branch) に \(snapshot.head.prefix(7)) を Push しますか？"
        showConfirmation = true
    }
    private func confirmMerge(_ snapshot: GitHubSnapshot, pr: GitHubPR) {
        var command = snapshot.target(workspaceId: workspace.id, type: "github.merge")
        command["number"] = pr.number; command["expectedPRHead"] = pr.headRefOid; command["method"] = method
        pending = command
        confirmation = "\(snapshot.repository) #\(pr.number)「\(pr.title)」を \(pr.baseRefName) に \(methodLabel(method)) でマージしますか？ 対象: \(pr.headRefOid.prefix(7))"
        showConfirmation = true
    }
    @MainActor private func perform(_ command: [String: Any], push: Bool = false) async -> Bool {
        guard model.supportsGitHub, !busy else {return false}; busy = true; notice = nil; defer {busy = false}
        do {
            if push {
                var pushCommand = command; pushCommand["type"] = "github.push"
                let _: GitHubResult = try await model.api.command(pushCommand)
            }
            let result: GitHubResult = try await model.api.command(command)
            notice = result.message
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

private struct GitHubCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: GitHubSnapshot
    let workspaceId: String
    let submit: ([String: Any], Bool) async -> Bool
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = ""
    @State private var draft = true
    @State private var push = true
    @State private var busy = false
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PR を作成").font(.title2.weight(.semibold))
            Text("\(snapshot.repository) · \(snapshot.branch) · \(snapshot.head.prefix(7))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            TextField("タイトル", text: $title)
            HStack {Text("マージ先"); TextField("main", text: $base)}
            Text("説明").font(.system(size: 12, weight: .medium))
            TextEditor(text: $bodyText).font(.system(size: 12)).frame(minHeight: 180).border(Color.secondary.opacity(0.2))
            Toggle("Draft として作成", isOn: $draft)
            Toggle("作成前にコミットを Push", isOn: $push)
            Text("コミット済みの変更を送信します。未コミットの変更は含まれません。").font(.system(size: 11)).foregroundStyle(.secondary)
            if failed {Text("作成を完了できませんでした。閉じてエラーを確認し、GitHub の状態を更新してください。").font(.system(size: 12)).foregroundStyle(.orange)}
            HStack {
                Spacer()
                if busy {ProgressView().controlSize(.small)}
                Button("閉じる") {dismiss()}.disabled(busy)
                Button(push ? "Push して PR を作成" : "PR を作成") {
                    busy = true
                    var command = snapshot.target(workspaceId: workspaceId, type: "github.create")
                    command["title"] = title; command["body"] = bodyText; command["base"] = base; command["draft"] = draft
                    Task {let success = await submit(command, push); busy = false; failed = !success; if success {dismiss()}}
                }.buttonStyle(.borderedProminent).disabled(busy || failed || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.isEmpty || base == snapshot.branch)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(busy)
        .onAppear {base = snapshot.defaultBranch}
    }
}
