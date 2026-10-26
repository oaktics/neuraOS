import SwiftUI

struct SourcePullRequest: Decodable, Identifiable, Equatable {
    let number: Int
    let title: String
    let state: String
    let headRefName: String
    var id: Int {number}
    var stateLabel: String {state == "MERGED" ? "マージ済み" : state == "CLOSED" ? "クローズ済み" : "オープン"}
}
struct SourcePullRequests: Decodable {let pullRequests: [SourcePullRequest]}

struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) var dismiss
    @State private var projectId = ""
    @State private var source = "latest"
    @State private var base = ""
    @State private var query = ""
    @State private var pullRequests: [SourcePullRequest] = []
    @State private var selectedPR: SourcePullRequest?
    @State private var loading = false
    @State private var loadError: String?
    @State private var reload = 0
    private var busy: Bool {model.isBusy("project.create.\(projectId)")}
    private var trimmedBase: String {base.trimmingCharacters(in: .whitespacesAndNewlines)}
    private var supportsPR: Bool {model.state.features?.contains("workspace.from-pr") == true}
    private var requestKey: String {"\(projectId)|\(source)|\(query)|\(reload)"}
    private var canCreate: Bool {
        model.connected && !projectId.isEmpty && !busy && model.state.features?.contains("workspace.remote-default") == true &&
        (source != "ref" || !trimmedBase.isEmpty) && (source != "pr" || (supportsPR && selectedPR != nil && !loading))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新しい作業").font(.system(size: 20, weight: .semibold))
            Text("選んだコードから、新しいブランチとworktreeを作成します。").foregroundStyle(.secondary)
            Picker("プロジェクト", selection: $projectId) {
                ForEach(model.gitProjects) {Text($0.name).tag($0.id)}
            }.disabled(busy)
            Picker("作成元", selection: $source) {
                Text("最新コード").tag("latest")
                Text("PR").tag("pr")
                Text("ブランチ・コミット").tag("ref")
            }.pickerStyle(.segmented).disabled(busy)
            sourceContent
            HStack {
                Button("キャンセル") {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                if busy {ProgressView().controlSize(.small)}
                Button("作成") {
                    let project = projectId, ref = source == "ref" ? trimmedBase : nil
                    let pr = source == "pr" ? selectedPR.map {String($0.number)} : nil
                    Task {await model.createWorkspace(projectId: project, base: ref, pullRequest: pr)}
                }.keyboardShortcut(.defaultAction).disabled(!canCreate)
            }
        }
        .padding(28).frame(width: 540)
        .onAppear {projectId = model.gitProjects.first(where: {$0.id == model.selected?.projectId})?.id ?? model.gitProjects.first?.id ?? ""}
        .onChange(of: projectId) {_, _ in selectedPR = nil; pullRequests = []}
        .onChange(of: query) {_, _ in selectedPR = nil; pullRequests = []}
        .onChange(of: source) {_, _ in selectedPR = nil}
        .task(id: requestKey) {await loadPullRequests()}
    }
    @ViewBuilder private var sourceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if source == "latest" {
                Text("通常の開発はこちら").font(.headline)
                Text("originのデフォルトブランチを取得し、最新のコードから始めます。").foregroundStyle(.secondary)
            } else if source == "ref" {
                TextField("ブランチ名・タグ・コミットID", text: $base).textFieldStyle(.roundedBorder)
                Text("例: staging、neura/worktree-12345678、v1.0、コミットID。HEADはプロジェクトの元フォルダの現在のコミットです。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("手元にあるコードを起点にします。リモートの再取得は行いません。入力したブランチそのものには切り替わりません。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if supportsPR {
                    HStack {
                        TextField("PRタイトル・番号（#123）・URL", text: $query).textFieldStyle(.roundedBorder)
                        Button {reload += 1} label: {Image(systemName: "arrow.clockwise")}.help("PRを再取得")
                    }
                    Text("Closed／Mergedも含めて表示します。古いPRは番号やURLで探せます。")
                        .font(.caption).foregroundStyle(.secondary)
                    if loading {ProgressView("PRを取得中…").frame(maxWidth: .infinity, minHeight: 160)}
                    else if let loadError {
                        Text(loadError).foregroundStyle(.red).textSelection(.enabled).frame(minHeight: 80)
                        Button("再試行") {reload += 1}
                    } else if pullRequests.isEmpty {
                        Text("該当するPRがありません。番号・URLまたは検索語を確認してください。")
                            .foregroundStyle(.secondary).frame(minHeight: 100)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(pullRequests) {pr in
                                    Button {selectedPR = pr} label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: selectedPR?.id == pr.id ? "checkmark.circle.fill" : "circle")
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("#\(pr.number)  \(pr.title)").lineLimit(2)
                                                Text("\(pr.stateLabel) · \(pr.headRefName)").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selectedPR?.id == pr.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(height: 190)
                    }
                    Text("PRの最終コミットから別ブランチを作ります。元PRへのpush先は引き継ぎません。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("PRから作成するにはDaemonを更新してください。").foregroundStyle(.secondary)
                }
            }
        }.disabled(busy)
    }
    @MainActor private func loadPullRequests() async {
        selectedPR = nil; pullRequests = []; loadError = nil; loading = false
        guard source == "pr", supportsPR, !projectId.isEmpty else {return}
        let key = requestKey, project = projectId, search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(300))
            let result: SourcePullRequests = try await model.api.get("v1/projects/\(project)/pull-requests", query: ["query": search])
            guard !Task.isCancelled, key == requestKey else {return}
            pullRequests = result.pullRequests
            loading = false
        } catch {
            guard !Task.isCancelled, key == requestKey else {return}
            loadError = error.localizedDescription; loading = false
        }
    }
}
