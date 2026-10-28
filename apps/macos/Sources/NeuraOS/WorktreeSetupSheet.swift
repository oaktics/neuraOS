import SwiftUI

private struct DetectedSetupScripts: Decodable {let scripts: [String]}
private struct SetupResult: Decodable {let ok: Bool}

struct WorktreeSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var script = ""
    @State private var scripts: [String] = []
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("worktreeのセットアップ").font(.title2.bold())
            Text(project.name).foregroundStyle(.secondary)
            Text("新しいworktreeで、エージェント起動前に実行するシェルスクリプトを設定します。")
            TextField("例: scripts/worktree-setup.sh", text: $script).textFieldStyle(.roundedBorder)
            Text("リポジトリ内の相対パス。空欄で無効になります。保存したスクリプトを各worktreeのルートでbashにより実行します。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("検出した候補").font(.headline)
                Spacer()
                if loading {ProgressView().controlSize(.small)}
                Button("再検出") {Task {await detect()}}.disabled(loading || saving)
            }
            if scripts.isEmpty && !loading {Text("候補はありません。パスを直接入力できます。").foregroundStyle(.secondary)}
            ForEach(scripts, id: \.self) {path in
                Button {script = path} label: {Label(path, systemImage: script == path ? "checkmark.circle.fill" : "doc.text")}
                    .buttonStyle(.plain)
            }
            if let error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
            HStack {
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                if saving {ProgressView().controlSize(.small)}
                Button("保存") {Task {await save()}}.keyboardShortcut(.defaultAction)
                    .disabled(saving || !model.connected)
            }
        }.padding(24).frame(width: 520).disabled(saving)
            .task {script = project.worktreeSetup ?? ""; await detect()}
    }
    private func detect() async {
        loading = true; error = nil
        defer {loading = false}
        do {let result: DetectedSetupScripts = try await model.api.get("v1/projects/\(project.id)/setup-scripts"); scripts = result.scripts}
        catch {self.error = error.localizedDescription}
    }
    private func save() async {
        saving = true; error = nil
        defer {saving = false}
        do {
            let _: Project = try await model.api.command(["type": "project.set-worktree-setup", "projectId": project.id, "script": script.trimmingCharacters(in: .whitespacesAndNewlines)])
            await model.refresh(); dismiss()
        } catch {self.error = error.localizedDescription}
    }
}

struct WorktreeSetupStatus: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    @State private var showLog = false
    @State private var retrying = false
    @State private var error: String?
    private var setup: WorktreeSetup? {model.state.workspaces.first(where: {$0.id == workspace.id})?.setup ?? workspace.setup}
    var body: some View {
        if let setup {
            HStack {
                if setup.status == "running" {ProgressView().controlSize(.small)}
                Text(setup.status == "running" ? "セットアップ実行中" : setup.status == "failed" ? "セットアップ失敗" : "セットアップ完了")
                Text(setup.script).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("ログ") {showLog = true}
                if setup.status == "failed" {
                    Button("再実行") {Task {
                        retrying = true
                        defer {retrying = false}
                        do {let _: SetupResult = try await model.api.command(["type": "workspace.setup", "workspaceId": workspace.id]); await model.refresh()}
                        catch {self.error = error.localizedDescription}
                    }}.disabled(retrying || !model.connected)
                }
            }.font(.caption).padding(8)
                .sheet(isPresented: $showLog) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("セットアップログ").font(.headline)
                        if let message = self.setup?.error {Text(message).foregroundStyle(.red)}
                        ScrollView {Text(self.setup?.output.isEmpty == false ? self.setup!.output : "出力はまだありません。")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)}
                        Button("閉じる") {showLog = false}.keyboardShortcut(.cancelAction)
                    }.padding(20).frame(width: 680, height: 440)
                }
                .alert("セットアップ", isPresented: Binding(get: {error != nil}, set: {if !$0 {error = nil}})) {
                    Button("OK") {error = nil}
                } message: {Text(error ?? "")}
        }
    }
}
