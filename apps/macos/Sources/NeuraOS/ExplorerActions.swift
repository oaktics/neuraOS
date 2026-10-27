import AppKit
import SwiftUI

struct ExplorerChange {
    let oldPath: String?
    let newPath: String?
}

enum ExplorerOperation: String, CaseIterable, Identifiable {
    case newFile = "新規ファイル", newFolder = "新規フォルダ", rename = "名前変更", move = "移動", duplicate = "複製", trash = "ゴミ箱に移動"
    var id: String {rawValue}
}

enum ExplorerFiles {
    // Resolve every existing component and reject links for mutations, including links within the root.
    static func target(root: String, path: String, mustExist: Bool) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !(path as NSString).isAbsolutePath,
              !parts.contains(where: {$0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git"}), !path.contains("\0") else {
            throw CocoaError(.fileReadNoPermission)
        }
        var url = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {throw CocoaError(.fileReadNoPermission)}
            } else if mustExist || index < parts.count - 1 {throw CocoaError(.fileNoSuchFile)}
        }
        return url
    }
    static func perform(_ operation: ExplorerOperation, root: String, source: String, destination: String) throws -> ExplorerChange {
        let fm = FileManager.default
        if operation == .trash {
            let from = try target(root: root, path: source, mustExist: true)
            try fm.trashItem(at: from, resultingItemURL: nil)
            return ExplorerChange(oldPath: source, newPath: nil)
        }
        let to = try target(root: root, path: destination, mustExist: false)
        guard !fm.fileExists(atPath: to.path) else {throw CocoaError(.fileWriteFileExists)}
        switch operation {
        case .newFile: try Data().write(to: to, options: .withoutOverwriting)
        case .newFolder: try fm.createDirectory(at: to, withIntermediateDirectories: false)
        case .rename, .move, .duplicate:
            let from = try target(root: root, path: source, mustExist: true)
            guard !to.path.hasPrefix(from.path + "/") else {throw CocoaError(.fileWriteInvalidFileName)}
            if operation == .duplicate {try fm.copyItem(at: from, to: to)}
            else {try fm.moveItem(at: from, to: to)}
        case .trash: break
        }
        return ExplorerChange(oldPath: operation == .move || operation == .rename ? source : nil, newPath: destination)
    }
    static func contains(_ path: String, in parent: String) -> Bool {path == parent || path.hasPrefix(parent + "/")}
    static func remap(_ path: String, change: ExplorerChange) -> String? {
        guard let old = change.oldPath, contains(path, in: old) else {return path}
        return change.newPath.map {$0 + path.dropFirst(old.count)}
    }
}

struct ExplorerActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let workspaceId: String
    let path: String
    let directory: Bool
    let dirtyPaths: Set<String>
    let onChange: (ExplorerChange) -> Void
    @State private var operation: ExplorerOperation?
    @State private var destination = ""
    @State private var failure: String?
    @State private var busy = false
    private var workspace: Workspace? {model.state.workspaces.first {$0.id == workspaceId}}
    private var hasEdits: Bool {dirtyPaths.contains {ExplorerFiles.contains($0, in: path)}}
    func body(content: Content) -> some View {
        content.contextMenu {
            if directory {
                Button("新規ファイル…") {prepare(.newFile)}
                Button("新規フォルダ…") {prepare(.newFolder)}
                Divider()
            }
            if !path.isEmpty {
                Button("名前変更…") {prepare(.rename)}.disabled(hasEdits)
                Button("移動先を指定…") {prepare(.move)}.disabled(hasEdits)
                Button("複製…") {prepare(.duplicate)}
                Divider()
            }
            Button("相対パスをコピー") {copy(path)}
            Button("絶対パスをコピー") {if let workspace {copy(URL(fileURLWithPath: workspace.path).appendingPathComponent(path).path)}}
            Button("Finderで表示") {
                if let workspace {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.path).appendingPathComponent(path)])}
            }
            if !path.isEmpty {
                Divider()
                Button("ゴミ箱に移動…", role: .destructive) {prepare(.trash)}.disabled(hasEdits)
                if hasEdits {Text("未保存の変更を保存してから操作してください")}
            }
        }
        .sheet(item: $operation) {action in
            VStack(alignment: .leading, spacing: 16) {
                Text(action.rawValue).font(.headline)
                if action == .trash {Text("「\(path)」をゴミ箱に移動します。Finderから元に戻せます。").lineLimit(4)}
                else {
                    Text("ワークスペースからの相対パスを指定してください。").foregroundStyle(.secondary)
                    TextField("例: docs/note.md", text: $destination).textFieldStyle(.roundedBorder).onSubmit {execute(action)}
                }
                if let failure {Text(failure).foregroundStyle(.red).textSelection(.enabled)}
                HStack {
                    Spacer()
                    Button("キャンセル") {operation = nil}.keyboardShortcut(.cancelAction).disabled(busy)
                    Button(action.rawValue) {execute(action)}.keyboardShortcut(.defaultAction).disabled(busy || (action != .trash && destination.isEmpty))
                }
            }.padding(24).frame(width: 440).interactiveDismissDisabled(busy)
        }
    }
    private func prepare(_ action: ExplorerOperation) {
        failure = nil
        switch action {
        case .newFile, .newFolder: destination = path.isEmpty ? "" : path + "/"
        case .duplicate:
            let ns = path as NSString
            let ext = ns.pathExtension
            destination = ns.deletingPathExtension + " copy" + (ext.isEmpty ? "" : "." + ext)
        default: destination = path
        }
        operation = action
    }
    private func execute(_ action: ExplorerOperation) {
        guard !busy, let workspace else {return}
        guard !([.move, .rename, .trash].contains(action) && hasEdits) else {failure = "未保存の変更を保存してください。"; return}
        if action != .trash, dirtyPaths.contains(where: {ExplorerFiles.contains($0, in: destination)}) {
            failure = "移動先に未保存の編集があります。先に保存してください。"; return
        }
        busy = true
        let root = workspace.path, source = path, target = destination
        Task {
            do {
                let change = try await Task.detached {try ExplorerFiles.perform(action, root: root, source: source, destination: target)}.value
                onChange(change); operation = nil
                model.workspaceUpdated.send(workspaceId)
            } catch {failure = error.localizedDescription}
            busy = false
        }
    }
    private func copy(_ value: String) {NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)}
}
