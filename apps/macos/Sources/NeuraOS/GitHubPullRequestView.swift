import SwiftUI

/// Presentation is shared by summary badges, check rows, and merge guidance.
enum GitHubPresentation {
    static func failed(_ state: String) -> Bool {["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(state)}
    static func checkLabel(_ state: String) -> String {
        switch state {
        case "SUCCESS": return "成功"
        case "NEUTRAL": return "中立"
        case "SKIPPED": return "スキップ"
        case "FAILURE", "ERROR", "STARTUP_FAILURE": return "失敗"
        case "CANCELLED": return "キャンセル"
        case "TIMED_OUT": return "タイムアウト"
        case "ACTION_REQUIRED": return "操作が必要"
        case "IN_PROGRESS", "PENDING", "EXPECTED": return "実行中"
        case "QUEUED", "WAITING", "REQUESTED": return "待機中"
        default: return "状態不明"
        }
    }
    static func reviewLabel(_ state: String?) -> String {
        switch state {
        case "APPROVED": return "承認済み"
        case "CHANGES_REQUESTED": return "修正依頼"
        case "REVIEW_REQUIRED": return "レビュー待ち"
        case "COMMENTED": return "レビュー"
        case "DISMISSED": return "取り消し済み"
        default: return "指定なし"
        }
    }
    static func mergeLabel(_ state: String) -> String {
        switch state {
        case "CLEAN": return "競合なし"
        case "DIRTY": return "競合あり"
        case "BEHIND": return "ベースの更新が必要"
        case "BLOCKED": return "マージ条件の確認が必要"
        case "UNSTABLE": return "チェックを確認"
        case "DRAFT": return "Draft"
        case "HAS_HOOKS": return "フックの確認が必要"
        default: return "状態を確認中"
        }
    }
    static func relativeDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {return value.isEmpty ? "日時不明" : value}
        let relative = RelativeDateTimeFormatter(); relative.locale = Locale(identifier: "ja_JP")
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

struct GitHubPullRequestView: View {
    let pr: GitHubPR
    let snapshot: GitHubSnapshot
    let disabled: Bool
    @Binding var method: String
    let merge: () -> Void
    @State var tab = "overview"
    @State private var reviewsOnly = false
    @State private var search = ""
    @State private var commentPage = 0
    private let commentsPerPage = 20
    private var failures: Int {pr.checks.filter {GitHubPresentation.failed($0.state)}.count}
    private var passed: Int {pr.checks.filter(\.passed).count}
    private var statusColor: Color {pr.state == "MERGED" ? .purple : pr.state == "CLOSED" ? .red : pr.isDraft ? .secondary : .green}
    private var filteredComments: [GitHubComment] {
        pr.comments.filter {(!reviewsOnly || $0.kind != "comment") && (search.isEmpty || "\($0.body) \($0.author) \($0.path ?? "")".localizedCaseInsensitiveContains(search))}
    }

    private var commentPageCount: Int {max(1, (filteredComments.count + commentsPerPage - 1) / commentsPerPage)}
    private var currentCommentPage: Int {min(commentPage, commentPageCount - 1)}
    private var visibleComments: [GitHubComment] {
        Array(filteredComments.dropFirst(currentCommentPage * commentsPerPage).prefix(commentsPerPage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 6) {
                metric(pr.checks.isEmpty ? "CI なし" : "\(passed)/\(pr.checks.count) CI", icon: failures > 0 ? "xmark.circle.fill" : passed == pr.checks.count && !pr.checks.isEmpty ? "checkmark.circle.fill" : "clock", color: failures > 0 ? .red : passed == pr.checks.count && !pr.checks.isEmpty ? .green : .secondary)
                metric(GitHubPresentation.reviewLabel(pr.reviewDecision), icon: "person.crop.circle.badge.checkmark", color: pr.reviewDecision == "APPROVED" ? .green : pr.reviewDecision == "CHANGES_REQUESTED" ? .orange : .secondary)
                metric("\(pr.unresolvedThreads) 未解決", icon: "text.bubble", color: pr.unresolvedThreads > 0 ? .orange : .secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker("PR の表示", selection: $tab) {
                Text("概要").tag("overview")
                Text("会話 \(pr.comments.count)").tag("conversation")
                Text("CI \(pr.checks.count)").tag("checks")
                Text("ファイル").tag("files")
            }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case "conversation": conversation
            case "checks": checks
            case "files": files
            default: overview
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(pr.label, systemImage: pr.state == "MERGED" ? "arrow.triangle.merge" : pr.isDraft ? "circle.dashed" : "arrow.triangle.pull")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(statusColor.opacity(0.12), in: Capsule())
                Text("#\(pr.number)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let url = URL(string: pr.url) {Link(destination: url) {Image(systemName: "arrow.up.right.square")}.help("GitHub で PR を開く")}
            }
            Text(pr.title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let author = pr.author {Label(author.login, systemImage: "person.crop.circle").font(.system(size: 11)).foregroundStyle(.secondary)}
            HStack(spacing: 6) {
                branch(pr.headRefName)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                branch(pr.baseRefName)
            }.font(.system(size: 10, design: .monospaced))
            if let additions = pr.additions, let deletions = pr.deletions {
                HStack(spacing: 8) {
                    Label("\(pr.changedFiles ?? pr.files?.count ?? 0) ファイル", systemImage: "doc.on.doc").foregroundStyle(.secondary)
                    Text("+\(additions)").foregroundStyle(.green)
                    Text("−\(deletions)").foregroundStyle(.red)
                    Spacer(minLength: 0)
                }.font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("説明", icon: "text.alignleft") {
                if pr.body.isEmpty {Text("説明はありません").foregroundStyle(.secondary)}
                else {GitHubMarkdown(source: pr.body, baseURL: URL(string: pr.url))}
            }
            section("マージ", icon: "arrow.triangle.merge") {
                Label(GitHubPresentation.mergeLabel(pr.mergeStateStatus), systemImage: pr.mergeStateStatus == "CLEAN" ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(pr.mergeStateStatus == "CLEAN" ? .green : .secondary)
                if pr.state == "OPEN" {
                    if pr.headRefOid != snapshot.head {Label("PR とローカルのコミットが異なります。Push または更新後に確認してください。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)}
                    if pr.isDraft {Text("Draft です。GitHub でレビュー可能に変更できます。").foregroundStyle(.secondary)}
                    if failures > 0 {Text("\(failures) 件のチェックに問題があります。").foregroundStyle(.red)}
                    if pr.unresolvedThreads > 0 {Text("\(pr.unresolvedThreads) 件のレビュースレッドが未解決です。").foregroundStyle(.orange)}
                    if pr.reviewDecision == "CHANGES_REQUESTED" {Text("レビューの修正依頼を確認してください。").foregroundStyle(.orange)}
                    Picker("方式", selection: $method) {ForEach(snapshot.mergeMethods, id: \.self) {Text(methodLabel($0)).tag($0)}}.controlSize(.small)
                    Button(action: merge) {Label("PR をマージ…", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity)}
                        .buttonStyle(.borderedProminent).tint(.green)
                        .disabled(disabled || !pr.canMerge || pr.headRefOid != snapshot.head || !snapshot.mergeMethods.contains(method))
                    if !pr.canMerge {Text("CI・レビュー・競合などの条件が整うとマージできます。").font(.system(size: 11)).foregroundStyle(.secondary)}
                }
            }
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pr.checks.isEmpty {empty("チェックはありません", icon: "checkmark.shield")}
            else {
                Text("\(passed) 件完了 · \(failures) 件に問題 · \(pr.checks.count - passed - failures) 件待機・実行中").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(pr.checks) {check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : GitHubPresentation.failed(check.state) ? "xmark.circle.fill" : "clock")
                            .foregroundStyle(check.passed ? .green : GitHubPresentation.failed(check.state) ? .red : .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(check.name).fontWeight(.medium).textSelection(.enabled)
                            Text(GitHubPresentation.checkLabel(check.state)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let value = check.url, let url = URL(string: value), url.scheme == "https" {
                            Link(destination: url) {Image(systemName: "arrow.up.right.square")}.help("チェックの詳細を開く")
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("コメント・投稿者・ファイルを検索", text: $search).textFieldStyle(.roundedBorder)
            Toggle("レビューのみ", isOn: $reviewsOnly).toggleStyle(.checkbox).font(.system(size: 11))
            if filteredComments.isEmpty {empty(pr.comments.isEmpty ? "コメントはまだありません" : "一致するコメントはありません", icon: "bubble.left.and.bubble.right")}
            if commentPageCount > 1 { commentPagination }
            ForEach(visibleComments) {comment in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(comment.author.prefix(1)).uppercased()).font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26).background(Color.accentColor.opacity(0.12), in: Circle()).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.author).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(GitHubPresentation.relativeDate(comment.createdAt)).font(.system(size: 10)).foregroundStyle(.secondary).help(comment.createdAt)
                        }
                        Spacer(minLength: 0)
                        if let url = URL(string: comment.url) {Link(destination: url) {Image(systemName: "arrow.up.right.square")}.help("GitHub で開く")}
                    }
                    if let state = comment.state, !state.isEmpty {
                        metric(GitHubPresentation.reviewLabel(state), icon: state == "APPROVED" ? "checkmark.circle" : "text.bubble", color: state == "APPROVED" ? .green : state == "CHANGES_REQUESTED" ? .orange : .secondary)
                    }
                    if let path = comment.path {
                        Label("\(path)\(comment.line.map {":\($0)"} ?? "")\(comment.outdated ? " · 過去の差分" : "")", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !comment.body.isEmpty {GitHubMarkdown(source: comment.body, baseURL: URL(string: comment.url))}
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.16)))
            }
            if commentPageCount > 1 { commentPagination }
        }
        .onChange(of: search) {_, _ in commentPage = 0}
        .onChange(of: reviewsOnly) {_, _ in commentPage = 0}
        .onChange(of: pr.url) {_, _ in commentPage = 0}
    }

    private var commentPagination: some View {
        HStack {
            Button("前へ") {commentPage = currentCommentPage - 1}.disabled(currentCommentPage == 0)
            Spacer(minLength: 4)
            Text("\(currentCommentPage + 1) / \(commentPageCount) ページ").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("次へ") {commentPage = currentCommentPage + 1}.disabled(currentCommentPage + 1 >= commentPageCount)
        }.controlSize(.small)
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let files = pr.files {
                ForEach(files) {file in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(file.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("+\(file.additions)").foregroundStyle(.green)
                            Text("−\(file.deletions)").foregroundStyle(.red)
                        }.font(.system(size: 10, design: .monospaced))
                    }.padding(.vertical, 6)
                    Divider()
                }
                if files.isEmpty {empty("変更ファイルはありません", icon: "doc.text")}
                if let total = pr.changedFiles, total > files.count {Text("\(total) 件中 \(files.count) 件を表示。すべての差分は GitHub で確認できます。").foregroundStyle(.secondary)}
            } else {Text("変更ファイルの取得には Daemon の更新が必要です。").foregroundStyle(.secondary)}
            if let url = URL(string: pr.url + "/files") {Link(destination: url) {Label("GitHub で差分を確認", systemImage: "arrow.up.right.square")}.padding(.top, 6)}
        }
    }

    private func branch(_ name: String) -> some View {
        Text(name).lineLimit(1).truncationMode(.middle).padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4)).help(name)
    }
    private func metric(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.85).padding(.horizontal, 6).padding(.vertical, 5)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)).help(title)
    }
    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func empty(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) {Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.tertiary); Text(title).foregroundStyle(.secondary)}
            .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}
