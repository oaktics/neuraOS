import AppKit
import SwiftUI
import QuickLookUI
import UniformTypeIdentifiers

struct OpenDocument: Codable, Equatable {
    var original: FileContent
    var text: String
    var dirty: Bool {text != original.content}
}

enum FilePresentation {
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
    let workspace: Workspace
    let path: String
    let visible: Bool
    @Binding var documents: [String: OpenDocument]
    @State private var saving = false
    @State private var loading = false
    @State private var error: String?
    @State private var previewURL: URL?
    @State private var markdownPreview = true
    @State private var wrapsLines = true
    @State private var revision = 0
    @State private var confirmReload = false
    private var document: OpenDocument? {documents[path]}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(path)
                Spacer(minLength: 8)
                if let document {
                    if FilePresentation.isMarkdown(path) {
                        Picker("表示", selection: $markdownPreview) {
                            Text("編集").tag(false)
                            Text("プレビュー").tag(true)
                        }.pickerStyle(.segmented).frame(width: 150)
                    }
                    if !FilePresentation.isMarkdown(path) || !markdownPreview {
                        Toggle("折り返し", isOn: $wrapsLines).toggleStyle(.button)
                    }
                    Button("保存") {save()}.keyboardShortcut("s").disabled(!document.dirty || saving || !visible)
                }
                Button {if document?.dirty == true {confirmReload = true} else {revision += 1}} label: {Image(systemName: "arrow.clockwise")}
                    .disabled(loading || saving).help("ファイルを再読み込み")
            }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 10).frame(height: 36)
            Divider()
            if let document {
                if FilePresentation.isMarkdown(path) && markdownPreview {
                    if visible {
                        ScrollView {
                            GitHubMarkdown(source: document.text, baseURL: URL(fileURLWithPath: workspace.path).appendingPathComponent(path))
                                .padding(24).frame(maxWidth: 960).frame(maxWidth: .infinity)
                        }
                    } else {Color.clear}
                } else {
                    NativeTextEditor(text: Binding(get: {documents[path]?.text ?? ""}, set: {documents[path]?.text = $0}),
                                     editable: true, diff: false, visible: visible, wrapsLines: wrapsLines)
                }
            } else if let previewURL {
                if visible {FileQuickLook(url: previewURL).id(revision)} else {Color.clear}
            } else if loading {ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)}
            else {
                ContentUnavailableView {
                    Label("ファイルを表示できません", systemImage: "doc.questionmark")
                } description: {Text(error ?? "この形式のプレビューには対応していません。")}
                actions: {Button("再試行") {revision += 1}}
            }
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
    }

    private func load() async {
        guard document?.dirty != true else {return}
        loading = true; error = nil
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
            // Office documents, legacy encodings and other non-editable formats can
            // still be displayed by the system's installed preview providers.
            previewURL = try? FilePresentation.previewURL(root: workspace.path, path: path)
        }
    }

    private func save() {
        guard let doc = document, !saving else {return}
        saving = true; error = nil
        Task {
            defer {saving = false}
            do {
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
