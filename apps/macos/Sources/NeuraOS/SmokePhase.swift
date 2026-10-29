import Foundation

/// Only fixed test metadata is written; no view, conversation or credential values.
@MainActor enum SmokePhase {
    static let ids = ["cef-init", "page-ready", "sheet-show", "sheet-cancel", "sheet-dismiss", "app-modal", "browser-resume", "sidebar-tabs", "diagnostic-export", "exit"]
    static var output: FileHandle?
    static var started = ProcessInfo.processInfo.systemUptime
    static func configure(directory: URL) throws {
        let url = directory.appendingPathComponent("ui-phases.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        output = try FileHandle(forWritingTo: url)
        started = ProcessInfo.processInfo.systemUptime
    }
    static func record(_ id: String, _ state: String, index: Int? = nil, deadlineMs: Int? = nil) {
        guard ids.contains(id), ["start", "complete"].contains(state) else {return}
        var entry: [String: Any] = ["phase": id, "state": state, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)]
        if let index {entry["index"] = index}
        if let deadlineMs {entry["deadlineMs"] = deadlineMs}
        guard var bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {return}
        bytes.append(10)
        try? output?.write(contentsOf: bytes)
        // FileHandle writes directly to the kernel, with no stdio buffer to flush.
        // Avoid fsync on the UI thread: process termination does not discard kernel writes.
        // Deliberate hang only reachable from the guarded disposable smoke entrypoint.
        if state == "start", ProcessInfo.processInfo.environment["NEURA_UI_SMOKE_STALL_PHASE"] == id {
            while true {RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))}
        }
    }
}
