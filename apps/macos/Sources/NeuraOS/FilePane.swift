import AppKit
import SwiftUI
import QuickLookUI
import UniformTypeIdentifiers

enum FilePresentation {
    static func invalidateCleanDocument(_ path: String, in documents: inout [String: OpenDocument]) {
        // Inspect the current buffer: edits may have arrived while a read was pending.
        if documents[path]?.dirty != true {documents.removeValue(forKey: path)}
    }

    static func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains((path as NSString).pathExtension.lowercased())
    }

    static func prefersPreview(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else {return false}
        return [UTType.image, .pdf, .movie, .audio, .presentation, .spreadsheet].contains {type.conforms(to: $0)}
            || ["doc", "docx", "rtf", "rtfd", "pages", "key", "numbers"].contains((path as NSString).pathExtension.lowercased())
    }

    // Apply the same workspace boundary as the daemon before handing a URL to Quick Look.
    static func previewURL(root: String, path: String) throws -> URL {
        let parts = path.split(separator: "/")
        guard !(path as NSString).isAbsolutePath, !parts.contains(".."), !parts.contains(".git"), !path.contains("\0") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"),
              !url.pathComponents.dropFirst(base.pathComponents.count).contains(".git") else {throw CocoaError(.fileReadNoPermission)}
        guard FileManager.default.fileExists(atPath: url.path) else {throw CocoaError(.fileNoSuchFile)}
        return url
    }
}

struct FilePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let workspace: Workspace
    let path: String
    let visible: Bool
    // False for the pane that is on screen but not the one keyboard commands apply to:
    // two files side by side must not both answer ⌘S and ⌘F.
    var active = true
    let openFile: (String) -> Void
    @Binding var documents: [String: OpenDocument]
    @AppStorage(MarkdownMode.storageKey) private var storedMarkdownMode = MarkdownMode.rich.rawValue
    @StateObject private var rich: MarkdownEditorSession
    @State private var saving = false
    @State private var loading = false
    @State private var error: String?
    @State private var previewURL: URL?
    @State private var wrapsLines = true
    @State private var findRequest = 0
    @State private var finding = false
    @State private var findText = ""
    @State private var findIndex = 0
    @State private var linking = false
    @State private var linkAddress = ""
    @FocusState private var findFocused: Bool
    @State private var revision = 0
    @State private var confirmReload = false
    private var document: OpenDocument? {documents[path]}
    private var isMarkdown: Bool {FilePresentation.isMarkdown(path)}
    private var markdownMode: MarkdownMode {MarkdownMode.stored(storedMarkdownMode)}
    /// Which editor shows the text: the rich one, the plain one, or none (read-only preview).
    private var showsRich: Bool {isMarkdown && markdownMode == .rich}
    private var showsSource: Bool {!isMarkdown || markdownMode == .source}
    private var editable: Bool {!model.isWorkspaceBlocked(workspace.id)}
    /// A rich document is written to disk as it is edited, like a notes app; code and plain text keep an explicit ⌘S.
    private var autosaves: Bool {showsRich}
    private var text: Binding<String> {Binding(get: {documents[path]?.text ?? ""}, set: {documents[path]?.text = $0})}

    init(workspace: Workspace, path: String, visible: Bool, active: Bool = true, openFile: @escaping (String) -> Void, documents: Binding<[String: OpenDocument]>) {
        self.workspace = workspace; self.path = path; self.visible = visible; self.active = active
        self.openFile = openFile; _documents = documents
        _rich = StateObject(wrappedValue: MarkdownEditorSession(root: workspace.path, path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if finding && showsRich {findBar; Divider()}
            content
            if document != nil, let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled).padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("未保存の変更を破棄して再読み込みしますか？", isPresented: $confirmReload) {
            Button("破棄して再読み込み", role: .destructive) {documents.removeValue(forKey: path); revision += 1}
            Button("キャンセル", role: .cancel) {}
        }
        .task(id: revision) {await load()}
        .onReceive(model.workspaceUpdated) {id in
            if id == workspace.id, document?.dirty != true {revision += 1}
        }
        .onChange(of: document?.text) {if finding && showsRich {runFind()}}
        .task(id: autosaves ? document?.text : nil) {await autosave()}
        .onChange(of: visible) {if !visible, autosaves, document?.dirty == true {save()}}
        .onChange(of: colorScheme) {NotificationCenter.default.post(name: MarkdownCodeHighlighter.appearanceChanged, object: nil)}
    }

    // A rich document shows writing tools, as a word processor does; every other file shows where it lives.
    private var toolbar: some View {
        HStack(spacing: 2) {
            if showsRich, document != nil {formatBar.disabled(!editable || !visible)}
            else {Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(path).padding(.leading, 4)}
            Spacer(minLength: 8)
            if let document {
                if autosaves && error == nil {
                    // Nothing to press, but ⌘S still writes at once for those who reach for it.
                    Button("") {save()}.keyboardShortcut(active ? KeyboardShortcut("s") : nil).disabled(!document.dirty || !visible)
                        .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                } else if document.dirty {
                    Button(autosaves ? "保存を再試行" : "保存") {save()}.keyboardShortcut(active ? KeyboardShortcut("s") : nil).disabled(saving || !visible)
                        .controlSize(.small).padding(.trailing, 4)
                }
                if showsSource {toolbarIcon("arrow.turn.down.left", "行を折り返す", pressed: wrapsLines) {wrapsLines.toggle()}}
                if showsRich || showsSource {
                    toolbarIcon("magnifyingglass", "検索", pressed: finding && showsRich) {startFind()}
                        .keyboardShortcut(active ? KeyboardShortcut("f") : nil).disabled(!visible)
                }
            }
            moreMenu
        }.font(.system(size: 11)).padding(.horizontal, 8).frame(height: 36)
    }

    private func toolbarIcon(_ symbol: String, _ help: String, pressed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24)
                .background(pressed ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(pressed ? .primary : .secondary).help(help)
    }

    private var toolbarDivider: some View {Divider().frame(height: 14).padding(.horizontal, 5)}

    private var formatBar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("本文") {rich.restyleLines(.body)}
                Divider()
                ForEach(1...3, id: \.self) {level in Button("見出し \(level)") {rich.apply(.heading, level: level)}}
            } label: {
                Image(systemName: "textformat.size").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).help("見出し")
            toolbarDivider
            toolbarIcon("bold", "太字 (⌘B)", pressed: rich.bold) {rich.apply(.bold)}.keyboardShortcut(active ? KeyboardShortcut("b") : nil)
            toolbarIcon("italic", "斜体 (⌘I)", pressed: rich.italic) {rich.apply(.italic)}.keyboardShortcut(active ? KeyboardShortcut("i") : nil)
            toolbarIcon("strikethrough", "取り消し線") {rich.apply(.strikethrough)}
            toolbarIcon("chevron.left.forwardslash.chevron.right", "コード") {rich.apply(.inlineCode)}
            toolbarIcon("link", "リンク (⌘K)", pressed: linking) {startLink()}.keyboardShortcut(active ? KeyboardShortcut("k") : nil)
                .popover(isPresented: $linking, arrowEdge: .bottom) {linkPopover}
            toolbarDivider
            toolbarIcon("list.bullet", "箇条書き") {rich.apply(.bulletList)}
            toolbarIcon("list.number", "番号付きリスト") {rich.apply(.numberedList)}
            toolbarIcon("checklist", "チェックリスト") {rich.restyleLines(.checklist)}
            toolbarIcon("text.quote", "引用") {rich.apply(.quote)}
            toolbarIcon("curlybraces", "コードブロック") {rich.apply(.codeBlock)}
            toolbarIcon("minus", "区切り線") {rich.apply(.rule)}
        }
    }

    private var linkPopover: some View {
        HStack(spacing: 8) {
            TextField("リンク先のアドレス", text: $linkAddress).textFieldStyle(.roundedBorder).frame(width: 260)
                .onSubmit {commitLink()}
            Button("挿入") {commitLink()}.keyboardShortcut(.defaultAction)
                .disabled(linkAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }.font(.system(size: 12)).controlSize(.small).padding(10)
    }

    private func startLink() {
        // A copied address is almost always the one about to be linked.
        let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        linkAddress = copied.hasPrefix("http://") || copied.hasPrefix("https://") ? copied : ""
        linking = true
    }

    private func commitLink() {
        let address = linkAddress
        linking = false
        // The popover held the keyboard; wait for it to close before typing into the document.
        DispatchQueue.main.async {rich.insertLink(address)}
    }

    // Everything that is not writing: how the file is shown, and where it is.
    private var moreMenu: some View {
        Menu {
            if isMarkdown, document != nil {
                Picker("表示", selection: Binding(get: {markdownMode}, set: {switchMode($0)})) {
                    ForEach(MarkdownMode.allCases) {Text($0.title).tag($0)}
                }.pickerStyle(.inline)
                Divider()
            }
            Button("再読み込み") {if document?.dirty == true {confirmReload = true} else {revision += 1}}.disabled(loading || saving)
            Button("Finderで表示") {if let url = try? FilePresentation.previewURL(root: workspace.path, path: path) {NSWorkspace.shared.activateFileViewerSelecting([url])}}
            Button("外部アプリで開く") {if let url = try? FilePresentation.previewURL(root: workspace.path, path: path) {NSWorkspace.shared.open(url)}}
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).help("その他")
    }

    // The plain editor has AppKit's find bar; the rich editor is driven from this one.
    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("検索", text: $findText).textFieldStyle(.plain).focused($findFocused)
                .onSubmit {stepFind(NSEvent.modifierFlags.contains(.shift) ? -1 : 1)}
                .onChange(of: findText) {findIndex = 0; runFind()}
            if !findText.isEmpty {
                Text(rich.matchCount == 0 ? "見つかりません" : "\(min(findIndex, rich.matchCount - 1) + 1) / \(rich.matchCount)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Button {stepFind(-1)} label: {Image(systemName: "chevron.up")}.help("前を検索").disabled(rich.matchCount == 0)
            Button {stepFind(1)} label: {Image(systemName: "chevron.down")}.help("次を検索").disabled(rich.matchCount == 0)
            Button {closeFind()} label: {Image(systemName: "xmark")}.keyboardShortcut(.cancelAction).help("検索を閉じる")
        }.font(.system(size: 11)).controlSize(.small).buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 30)
    }

    @ViewBuilder private var content: some View {
        if document != nil {
            if showsRich {
                // A hidden tab's editor is parked by the engine with its undo history and scroll position.
                if visible {
                    MarkdownRichEditor(text: text, editable: editable, workspace: workspace, path: path, session: rich, openFile: openFile)
                } else {Color.clear}
            } else if showsSource {
                NativeTextEditor(text: text, editable: editable, diff: false, visible: visible, wrapsLines: wrapsLines,
                                 language: CodePresentation.language(path), showsLineNumbers: true, findRequest: findRequest)
            } else if visible {
                ScrollView {
                    GitHubMarkdown(source: document?.text ?? "", baseURL: WorkspaceMarkdownResources.baseURL(path: path),
                                   workspaceRoot: URL(fileURLWithPath: workspace.path), openFile: openFile)
                        .padding(24).frame(maxWidth: 960).frame(maxWidth: .infinity)
                }
            } else {Color.clear}
        } else if let previewURL {
            if visible {RichFilePreview(url: previewURL).id(revision)} else {Color.clear}
        } else if loading {ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)}
        else {
            ContentUnavailableView {
                Label("ファイルを表示できません", systemImage: "doc.questionmark")
            } description: {Text(error ?? "この形式のプレビューには対応していません。")}
            actions: {Button("再試行") {revision += 1}}
        }
    }

    /// Writes a rich document shortly after the last keystroke.
    private func autosave() async {
        guard autosaves, document?.dirty == true else {return}
        try? await Task.sleep(for: .milliseconds(800))
        // A save already under way took an older text: wait for it, then write the newer one.
        while saving, !Task.isCancelled {try? await Task.sleep(for: .milliseconds(150))}
        guard !Task.isCancelled, autosaves, document?.dirty == true else {return}
        save()
    }

    private func switchMode(_ mode: MarkdownMode) {
        if autosaves, document?.dirty == true {save()}
        closeFind()
        storedMarkdownMode = mode.rawValue
    }

    private func startFind() {
        guard showsRich else {findRequest += 1; return}
        finding = true; findFocused = true
        runFind()
    }

    private func runFind() {rich.find(findText, index: findIndex)}

    private func stepFind(_ step: Int) {
        guard rich.matchCount > 0 else {return}
        findIndex = (min(findIndex, rich.matchCount - 1) + step + rich.matchCount) % rich.matchCount
        runFind()
    }

    private func closeFind() {
        guard finding else {return}
        finding = false
        rich.clearFind()
    }

    private func load() async {
        guard document?.dirty != true else {return}
        loading = true; error = nil; previewURL = nil
        defer {loading = false}
        if FilePresentation.prefersPreview(path) {
            do {previewURL = try FilePresentation.previewURL(root: workspace.path, path: path)}
            catch {self.error = error.localizedDescription}
            return
        }
        do {
            let content: FileContent = try await model.api.get("v1/workspaces/\(workspace.id)/file", query: ["path": path])
            guard !Task.isCancelled, documents[path]?.dirty != true else {return}
            documents[path] = OpenDocument(original: content, text: content.content)
        } catch {
            guard !Task.isCancelled else {return}
            self.error = error.localizedDescription
            FilePresentation.invalidateCleanDocument(path, in: &documents)
            // Office documents, legacy encodings and other non-editable formats can
            // still be displayed by the system's installed preview providers.
            previewURL = try? FilePresentation.previewURL(root: workspace.path, path: path)
        }
    }

    private func save() {
        guard !model.isWorkspaceBlocked(workspace.id), let doc = document, !saving else {return}
        saving = true; error = nil
        Task {
            defer {saving = false}
            do {
                guard !model.isWorkspaceBlocked(workspace.id) else {return}
                let content: FileContent = try await model.api.command(["type": "file.save", "workspaceId": workspace.id,
                    "path": path, "content": doc.text, "expectedHash": doc.original.hash])
                documents[path]?.original = content
            } catch {self.error = error.localizedDescription}
        }
    }
}

struct FileQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL {view.previewItem = url as NSURL}
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {view.close()}
}
