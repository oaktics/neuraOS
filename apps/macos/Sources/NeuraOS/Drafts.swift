import Foundation

/// UI drafts stay on the viewing Mac, separately from project files.
@MainActor final class DraftCache {
    static let shared = DraftCache()
    private var values: [String: [String: OpenDocument]] = [:]
    private var pending: Task<Void, Never>?
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("neuraOS/NativeUI/\(Bundle.main.bundleIdentifier ?? "app.neuraos.native")/drafts")
    }
    func load(_ workspaceId: String) -> [String: OpenDocument] {
        if let cached = values[workspaceId] {return cached}
        let result = (try? Data(contentsOf: directory.appendingPathComponent(workspaceId + ".json"))).flatMap {try? JSONDecoder().decode([String: OpenDocument].self, from: $0)} ?? [:]
        values[workspaceId] = result; return result
    }
    func update(_ workspaceId: String, _ documents: [String: OpenDocument]) {
        values[workspaceId] = documents
        pending?.cancel()
        pending = Task {try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled {flush()}}
    }
    func flush() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (workspace, documents) in values {
                let target = directory.appendingPathComponent(workspace + ".json")
                let data = try JSONEncoder().encode(documents.filter {$0.value.dirty})
                try data.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            }
        } catch {NSLog("neuraOS: draft persistence failed (%@)", String(describing: type(of: error)))}
    }
}
