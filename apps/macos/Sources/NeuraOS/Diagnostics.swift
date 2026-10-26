import Foundation
import AppKit

// Only metadata belongs here: never error descriptions, command bodies, URLs or paths.
struct DiagnosticEvent: Codable {
    let time: Date
    let session: String
    let build: String
    let event: String
    let operation: String?
    let operationId: String?
    let durationMs: Int?
    let code: Int?
}

struct UIHeartbeat {
    private(set) var pending: TimeInterval?
    private(set) var hung = false
    mutating func tick(at now: TimeInterval) -> (probe: Bool, hang: TimeInterval?) {
        guard let pending else {self.pending = now; return (true, nil)}
        if now - pending >= 5 && !hung {hung = true; return (false, now - pending)}
        return (false, nil)
    }
    mutating func acknowledge(at now: TimeInterval) -> TimeInterval? {
        let duration = hung ? now - (pending ?? now) : nil
        pending = nil; hung = false
        return duration
    }
}

final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    let directory: URL
    private let queue = DispatchQueue(label: "neura.diagnostics", qos: .utility)
    private let session = UUID().uuidString
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    private var timer: DispatchSourceTimer?
    private var heartbeatState = UIHeartbeat()
    private var started = false
    private let limit: Int
    private let admission = NSLock()
    private var queued = 0
    init(directory: URL? = nil, limit: Int = 1_048_576) {
        let root = Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") as? String ?? NSHomeDirectory() + "/Library/Application Support/neuraOS/Developer"
        self.directory = directory ?? URL(fileURLWithPath: root).appendingPathComponent("diagnostics")
        self.limit = limit
    }
    func record(_ event: String, operation: String? = nil, id: String? = nil, duration: TimeInterval? = nil, code: Int? = nil) {
        admission.lock()
        guard queued < 256 else {admission.unlock(); return}
        queued += 1; admission.unlock()
        let value = DiagnosticEvent(time: Date(), session: session, build: build, event: event, operation: operation, operationId: id, durationMs: duration.map {Int(max(0, $0) * 1000)}, code: code)
        queue.async {
            self.write(value)
            self.admission.lock(); self.queued -= 1; self.admission.unlock()
        }
    }
    private func write(_ value: DiagnosticEvent) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("app.jsonl")
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= limit {
                let previous = directory.appendingPathComponent("app.previous.jsonl")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: file, to: previous)
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value); data.append(10)
            if !FileManager.default.fileExists(atPath: file.path) {FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])}
            let handle = try FileHandle(forWritingTo: file); defer {try? handle.close()}
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { /* Diagnostics must never break the user's operation. */ }
    }
    func start() {
        queue.async {
            guard !self.started else {return}; self.started = true
            try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let marker = self.directory.appendingPathComponent("session-\(ProcessInfo.processInfo.processIdentifier)")
            for file in (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.hasPrefix("session-") {
                guard let pid = Int32(file.lastPathComponent.dropFirst(8)), kill(pid, 0) != 0, errno == ESRCH else {continue}
                if let data = try? Data(contentsOf: file), let old = try? JSONDecoder().decode(DiagnosticEvent.self, from: data) {
                    self.write(DiagnosticEvent(time: Date(), session: old.session, build: old.build, event: "session.unclean", operation: nil, operationId: nil, durationMs: nil, code: nil))
                }
                try? FileManager.default.removeItem(at: file)
            }
            let event = DiagnosticEvent(time: Date(), session: self.session, build: self.build, event: "session.start", operation: nil, operationId: nil, durationMs: nil, code: nil)
            FileManager.default.createFile(atPath: marker.path, contents: try? JSONEncoder().encode(event), attributes: [.posixPermissions: 0o600])
            self.write(event)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.heartbeat() }
            self.timer = timer; timer.resume()
        }
    }
    private func heartbeat() {
        // systemUptime excludes sleep: closing the lid should not count as a UI hang.
        let now = ProcessInfo.processInfo.systemUptime
        let result = heartbeatState.tick(at: now)
        if let duration = result.hang {record("ui.hang", duration: duration)}
        guard result.probe else {return}
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}
            self.queue.async {
                if let duration = self.heartbeatState.acknowledge(at: ProcessInfo.processInfo.systemUptime) {self.record("ui.recovered", duration: duration)}
            }
        }
    }
    func stop() {
        record("session.end")
        queue.sync {
            timer?.cancel(); timer = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("session-\(ProcessInfo.processInfo.processIdentifier)"))
        }
    }
    func flush() {queue.sync {}}
    func export(to destination: URL) async throws {
        record("report.saved")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    var logs: [String: String] = [:]
                    for name in ["app.previous.jsonl", "app.jsonl", "daemon.previous.jsonl", "daemon.jsonl"] {
                        if let data = try? Data(contentsOf: self.directory.appendingPathComponent(name)), data.count <= 2_097_152 {logs[name] = String(decoding: data, as: UTF8.self)}
                    }
                    let report: [String: Any] = ["schemaVersion": 1, "build": self.build, "os": ProcessInfo.processInfo.operatingSystemVersionString, "logs": logs, "crashes": Self.crashSummaries()]
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: destination, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    continuation.resume()
                } catch {continuation.resume(throwing: error)}
            }
        }
    }
    // Never export raw .ips files: they can contain paths, arguments and memory.
    static func crashSummaries(root suppliedRoot: URL? = nil) -> [[String: String]] {
        let root = suppliedRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []).filter {$0.pathExtension == "ips" && $0.lastPathComponent.lowercased().hasPrefix("neuraos")}.sorted {$0.lastPathComponent > $1.lastPathComponent}.prefix(10)
        return files.compactMap {file in
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 10_000_000,
                  let data = try? Data(contentsOf: file), let newline = data.firstIndex(of: 10),
                  let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] else {return nil}
            var summary: [String: String] = [:]
            for key in ["timestamp", "app_version", "build_version", "bug_type", "incident_id"] {if let value = header[key] as? String {summary[key] = String(value.prefix(100))}}
            if let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any] {
                if let exception = body["exception"] as? [String: Any] {
                    for key in ["type", "signal"] {if let value = exception[key] as? String, value.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil {summary[key] = value}}
                }
                // UUID + image offset is enough to symbolicate against build artifacts without leaking paths.
                if let index = body["faultingThread"] as? Int, let threads = body["threads"] as? [[String: Any]], threads.indices.contains(index),
                   let frames = threads[index]["frames"] as? [[String: Any]], let images = body["usedImages"] as? [[String: Any]] {
                    summary["frames"] = frames.prefix(20).compactMap {frame -> String? in
                        guard let i = frame["imageIndex"] as? Int, images.indices.contains(i), let uuid = images[i]["uuid"] as? String, UUID(uuidString: uuid) != nil, let offset = frame["imageOffset"] as? Int else {return nil}
                        return "\(uuid)+\(offset)"
                    }.joined(separator: ",")
                }
            }
            return summary
        }
    }
}

@MainActor enum DiagnosticReport {
    static func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "neuraOS-diagnostics.json"
        panel.message = "操作名・処理時間・終了状態を保存します。会話本文や端末入力は含みません。"
        guard panel.runModal() == .OK, let url = panel.url else {return}
        Task {
            do {try await Diagnostics.shared.export(to: url); NSWorkspace.shared.activateFileViewerSelecting([url])}
            catch {let alert = NSAlert(); alert.messageText = "診断情報を保存できませんでした"; alert.runModal()}
        }
    }
}
