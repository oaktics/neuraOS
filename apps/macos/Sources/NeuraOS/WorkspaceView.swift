import SwiftUI
import AppKit

struct WorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    @State private var tab = "codex"
    @State private var git = GitStatus()
    @State private var selectedDiff: Diff?
    @State private var gitError: String?
    private let tabs: [(String, String, String)] = [("codex", "Codex", "sparkle"), ("claude", "Claude Code", "asterisk"), ("shell", "ターミナル", "terminal"), ("files", "ファイル", "doc"), ("browser", "ブラウザ", "globe")]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: workspace.supportsGit ? "arrow.triangle.branch" : "folder").foregroundStyle(.tertiary)
                Text(workspace.supportsGit ? (git.branch.isEmpty ? workspace.branch : git.branch) : (workspace.path as NSString).lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text(workspace.kind == "folder" ? "フォルダ" : workspace.kind == "worktree" ? "Worktree" : "元のリポジトリ").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 20).frame(height: 42)
            HStack(spacing: 20) {
                ForEach(tabs, id: \.0) {item in
                    Button {tab = item.0} label: {
                        HStack(spacing: 6) {Image(systemName: item.2); Text(item.1)}.font(.system(size: 12, weight: tab == item.0 ? .medium : .regular))
                            .foregroundStyle(tab == item.0 ? .primary : .secondary).frame(height: 35)
                            .overlay(alignment: .bottom) {if tab == item.0 {Rectangle().fill(Color.primary.opacity(0.65)).frame(height: 2)}}
                    }.buttonStyle(.plain)
                }
                if selectedDiff != nil {Button {tab = "diff"} label: {Label("差分", systemImage: "plus.forwardslash.minus").font(.system(size: 12)).foregroundStyle(tab == "diff" ? .primary : .secondary)}.buttonStyle(.plain)}
                Spacer(minLength: 0)
            }.padding(.horizontal, 20)
            Rectangle().fill(Palette.line).frame(height: 1)
            HSplitView {
                ZStack {
                    ForEach(["codex", "claude", "shell"], id: \.self) {provider in
                        TerminalPane(workspace: workspace, provider: provider, visible: tab == provider && model.selectedId == workspace.id)
                            .opacity(tab == provider ? 1 : 0).allowsHitTesting(tab == provider).accessibilityHidden(tab != provider)
                    }
                    FilePane(workspace: workspace, visible: tab == "files" && model.selectedId == workspace.id).opacity(tab == "files" ? 1 : 0).allowsHitTesting(tab == "files").accessibilityHidden(tab != "files")
                    BrowserPane(workspaceId: workspace.id, visible: tab == "browser" && model.selectedId == workspace.id).opacity(tab == "browser" ? 1 : 0).allowsHitTesting(tab == "browser").accessibilityHidden(tab != "browser")
                    if let diff = selectedDiff, tab == "diff" {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(diff.path).font(.system(size: 12, design: .monospaced)).padding(14)
                            Divider()
                            NativeTextEditor(text: .constant(diff.content), editable: false, diff: true)
                        }
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector && workspace.supportsGit {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {Text("変更").font(.system(size: 12, weight: .medium)); Text("\(git.changes.count)").font(.system(size: 11)).foregroundStyle(.tertiary); Spacer(); Button {Task {await refreshGit()}} label: {Image(systemName: "arrow.clockwise")}.buttonStyle(.plain).help("差分を更新")}.padding(15)
                        if let gitError {Text(gitError).font(.system(size: 11)).foregroundStyle(.secondary).padding(15)}
                        if git.changes.isEmpty && gitError == nil {
                            VStack(spacing: 9) {Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .light)); Text("変更はありません").font(.system(size: 11))}.foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 48)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(git.changes) {change in
                                    Button {Task {do {selectedDiff = try await model.api.get("v1/workspaces/\(workspace.id)/diff", query: ["path": change.path]); tab = "diff"} catch {model.report(error)}}} label: {
                                        HStack(spacing: 8) {Text(change.status.trimmingCharacters(in: .whitespaces)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(change.status == "??" ? .green : .orange).frame(width: 17); Text(change.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0)}.padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(change.path)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minWidth: 180, idealWidth: 235, maxWidth: 280)
                }
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack {Text(workspace.path).lineLimit(1).truncationMode(.middle); Spacer(); if model.busy {ProgressView().controlSize(.mini)}; if workspace.supportsGit {Text("\(git.changes.count) files changed")}}.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 16).frame(height: 27)
        }
        .onAppear {tab = UserDefaults.standard.string(forKey: "tab.\(workspace.id)") ?? "codex"}
        .onChange(of: tab) {_, value in UserDefaults.standard.set(value, forKey: "tab.\(workspace.id)")}
        .task {
            while !Task.isCancelled {if model.selectedId == workspace.id {await refreshGit()}; try? await Task.sleep(for: .seconds(3))}
        }
    }
    private func refreshGit() async {guard workspace.supportsGit else {return}; do {git = try await model.api.get("v1/workspaces/\(workspace.id)/git"); gitError = nil} catch {gitError = error.localizedDescription}}
}

struct TerminalPane: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    let provider: String
    let visible: Bool
    @State private var showStop = false
    private var title: String {provider == "codex" ? "Codex" : provider == "claude" ? "Claude Code" : "ターミナル"}
    var body: some View {
        let terminal = model.terminal(workspaceId: workspace.id, provider: provider)
        VStack(spacing: 0) {
            if let terminal {
                HStack(spacing: 8) {
                    Circle().fill(terminal.status == "running" ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(terminal.status == "running" ? "実行中" : terminal.status == "interrupted" ? "Daemonの再起動により中断" : "終了").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if terminal.status == "running" {Button("停止") {showStop = true}.font(.system(size: 11)).buttonStyle(.plain)}
                    else {
                        if provider != "shell" {Button("履歴から再開") {Task {await model.openTerminal(workspace, provider: provider, resume: true)}}.font(.system(size: 11))}
                        Button("新しく起動") {Task {await model.openTerminal(workspace, provider: provider)}}.font(.system(size: 11))
                    }
                }.padding(.horizontal, 16).frame(height: 32)
                if visible {NativeTerminal(terminal: terminal, api: model.api, onError: {model.report($0)}).padding(.horizontal, 14).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity).id(terminal.id)}
                else {Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)}
            } else {
                VStack(spacing: 16) {
                    Image(systemName: provider == "shell" ? "terminal" : "sparkle").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.secondary)
                    Text("\(title)で作業する").font(.system(size: 19, weight: .medium))
                    Text(provider == "shell" ? "この作業フォルダでシェルを開きます。" : "ログイン済みのCLIを、そのまま使えます。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("\(title)を起動") {Task {await model.openTerminal(workspace, provider: provider)}}.controlSize(.large).disabled(model.busy || !model.connected)
                    if provider != "shell" {Button("以前の会話から再開") {Task {await model.openTerminal(workspace, provider: provider, resume: true)}}.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)}
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("\(title)のプロセスを停止しますか？", isPresented: $showStop) {Button("停止", role: .destructive) {if let terminal {Task {await model.stopTerminal(terminal)}}}}
    }
}

struct OpenDocument: Codable, Equatable {var original: FileContent; var text: String; var dirty: Bool {text != original.content}}
struct FilePane: View {
    @EnvironmentObject var model: AppModel
    let workspace: Workspace
    let visible: Bool
    @State private var documents: [String: OpenDocument] = [:]
    @State private var order: [String] = []
    @State private var selected: String?
    @State private var treeVersion = 0
    @State private var saving = false
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {Text("ファイル").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button {treeVersion += 1} label: {Image(systemName: "arrow.clockwise")}.buttonStyle(.plain).help("ファイル一覧を更新")}.padding(13)
                ScrollView {FileTree(workspaceId: workspace.id, path: "", selected: selected, onSelect: open).id(treeVersion).padding(.horizontal, 8)}
            }.frame(minWidth: 145, idealWidth: 190, maxWidth: 220)
            VStack(spacing: 0) {
                if let path = selected, let document = documents[path] {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {ForEach(order, id: \.self) {name in
                            Button {selected = name} label: {HStack(spacing: 5) {Text((name as NSString).lastPathComponent); if documents[name]?.dirty == true {Circle().frame(width: 5, height: 5)}}.font(.system(size: 11)).padding(10).background(selected == name ? Color.primary.opacity(0.05) : .clear)}.buttonStyle(.plain).help(name)
                        }}
                    }.frame(height: 36)
                    Rectangle().fill(Palette.line).frame(height: 1)
                    if visible {NativeTextEditor(text: Binding(get: {documents[path]?.text ?? ""}, set: {documents[path]?.text = $0}), editable: true, diff: false).frame(maxWidth: .infinity, maxHeight: .infinity).id(path)}
                    else {Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)}
                    HStack {Text(document.dirty ? "未保存" : "保存済み").foregroundStyle(.secondary); Spacer(); Button("保存") {save(path)}.keyboardShortcut("s").disabled(!document.dirty || saving || !visible)}.font(.system(size: 11)).padding(10)
                } else {Text("ファイルを選択").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)}
            }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {documents = DraftCache.shared.load(workspace.id); order = documents.keys.sorted(); selected = order.first}
        .onChange(of: documents) {_, value in DraftCache.shared.update(workspace.id, value)}
    }
    private func open(_ path: String) {
        if documents[path] != nil {selected = path; return}
        Task {do {let content: FileContent = try await model.api.get("v1/workspaces/\(workspace.id)/file", query: ["path": path]); documents[path] = OpenDocument(original: content, text: content.content); order.append(path); selected = path} catch {model.report(error)}}
    }
    private func save(_ path: String) {
        guard let doc = documents[path] else {return}; saving = true
        Task {defer {saving = false}; do {let content: FileContent = try await model.api.command(["type": "file.save", "workspaceId": workspace.id, "path": path, "content": doc.text, "expectedHash": doc.original.hash]); documents[path]?.original = content} catch {model.report(error)}}
    }
}
struct FileTree: View {
    @EnvironmentObject var model: AppModel
    let workspaceId: String; let path: String; let selected: String?; let onSelect: (String) -> Void
    @State private var entries: [FileEntry] = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error {Text(error).font(.system(size: 10)).foregroundStyle(.secondary)}
            ForEach(entries) {entry in
                if entry.isDirectory {FolderRow(workspaceId: workspaceId, entry: entry, selected: selected, onSelect: onSelect)}
                else {Button {onSelect(entry.path)} label: {HStack(spacing: 7) {Image(systemName: "doc").foregroundStyle(.tertiary); Text(entry.name).lineLimit(1); Spacer(minLength: 0)}.font(.system(size: 11)).padding(.vertical, 6).padding(.horizontal, 6).background(selected == entry.path ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())}.buttonStyle(.plain)}
            }
        }.task {do {let listing: DirectoryListing = try await model.api.get("v1/workspaces/\(workspaceId)/files", query: ["path": path]); entries = listing.entries} catch {self.error = error.localizedDescription}}
    }
}
struct FolderRow: View {
    let workspaceId: String; let entry: FileEntry; let selected: String?; let onSelect: (String) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {expanded.toggle()} label: {HStack(spacing: 5) {Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)); Image(systemName: "folder"); Text(entry.name).lineLimit(1); Spacer(minLength: 0)}.font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 6).contentShape(Rectangle())}.buttonStyle(.plain)
            if expanded {FileTree(workspaceId: workspaceId, path: entry.path, selected: selected, onSelect: onSelect).padding(.leading, 12)}
        }
    }
}

struct NativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var diff: Bool
    var visible: Bool = true
    func makeCoordinator() -> Coordinator {Coordinator(self)}
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = NSTextView(); editor.isRichText = false; editor.isEditable = editable; editor.isSelectable = true; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textColor = .labelColor; editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.delegate = context.coordinator; scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.isHidden = !visible
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else {return}
        let selection = editor.selectedRange(); editor.string = text
        editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
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
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor
        init(_ parent: NativeTextEditor) {self.parent = parent}
        func textDidChange(_ notification: Notification) {if let editor = notification.object as? NSTextView {parent.text = editor.string}}
    }
}
