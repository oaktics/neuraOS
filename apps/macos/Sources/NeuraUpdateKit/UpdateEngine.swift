import Foundation
import Darwin

public struct DaemonIdentity: Decodable {
    public let runtime: String?
    public let daemonInstanceId: String?
    public let daemonBuild: Int?
    public init(runtime: String?, daemonInstanceId: String?, daemonBuild: Int? = nil) {
        self.runtime = runtime; self.daemonInstanceId = daemonInstanceId; self.daemonBuild = daemonBuild
    }
    public var instance: UUID? {daemonInstanceId.flatMap(UUID.init(uuidString:))}
    public func isNewNative(after previous: DaemonIdentity?) -> Bool {
        runtime == "rust" && instance != nil && instance != previous?.instance
    }
}

public struct UpdateEngine {
    public var home: URL
    public var helper: URL
    public var run: CommandRunner = NativeCommand.run
    public var pause: (TimeInterval) -> Void = {Thread.sleep(forTimeInterval: $0)}
    public var daemonState: (() async -> DaemonIdentity?)?
    private let fm = FileManager.default
    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), helper: URL) {self.home = home; self.helper = helper}
    public var updates: URL {home.appendingPathComponent("Library/Application Support/neuraOS/Updates")}
    public var data: URL {home.appendingPathComponent("Library/Application Support/neuraOS/Developer")}
    public var plist: URL {home.appendingPathComponent("Library/LaunchAgents/app.neuraos.daemon.plist")}
    public var domain: String {"gui/\(getuid())"}
    public static let serviceID = "app.neuraos.daemon"
    private func execute(_ program: String, _ args: [String], _ timeout: TimeInterval = 30) throws -> String {
        let result = try run(program, args, timeout)
        guard result.status == 0 else {throw UpdateFailure(result.output.isEmpty ? "\(program) exited \(result.status)" : result.output)}
        return result.output
    }
    private func directory(_ url: URL) throws {try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])}
    private func remove(_ url: URL) throws {if fm.fileExists(atPath: url.path) {try fm.removeItem(at: url)}}
    public func launchAgent(daemon: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": Self.serviceID, "ProgramArguments": [daemon.path],
            "WorkingDirectory": daemon.deletingLastPathComponent().path,
            "EnvironmentVariables": ["NEURA_DEV_DATA_DIR": data.path, "NEURA_DEV_PORT": "4318", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
            "StandardOutPath": data.appendingPathComponent("daemon.log").path,
            "StandardErrorPath": data.appendingPathComponent("daemon-error.log").path
        ], format: .xml, options: 0)
    }
    public func installService(daemon: URL) throws {
        guard fm.isExecutableFile(atPath: daemon.path) else {throw UpdateFailure("native daemonがありません。")}
        try directory(data); try directory(plist.deletingLastPathComponent())
        let previous = fm.fileExists(atPath: plist.path) ? try Data(contentsOf: plist) : nil
        var stopped = false
        do {
            try launchAgent(daemon: daemon).write(to: plist, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
            _ = try execute("/usr/bin/plutil", ["-lint", plist.path])
            let result = try run("/bin/launchctl", ["bootout", "\(domain)/\(Self.serviceID)"], 5)
            guard result.status == 0 || result.status == 3 else {throw UpdateFailure(result.output)}
            stopped = true
            for attempt in 0..<20 {
                let started = try run("/bin/launchctl", ["bootstrap", domain, plist.path], 5)
                if started.status == 0 {return}
                guard started.status == 5 && attempt < 19 else {throw UpdateFailure(started.output)}
                pause(0.5)
            }
        } catch {
            if stopped {_ = try? run("/bin/launchctl", ["bootout", "\(domain)/\(Self.serviceID)"], 5)}
            if let previous {
                try previous.write(to: plist, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
                if stopped {_ = try? run("/bin/launchctl", ["bootstrap", domain, plist.path], 5)}
            } else {try remove(plist)}
            throw error
        }
    }
    public func service(_ action: String, daemon: URL) throws -> String {
        switch action {
        case "ensure": try bootstrap(daemon: daemon); return "neuraOS Daemon available (running service preserved)."
        case "install": try installService(daemon: daemon); return "neuraOS native Daemon installed."
        case "stop": return try execute("/bin/launchctl", ["bootout", "\(domain)/\(Self.serviceID)"])
        case "restart": return try execute("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(Self.serviceID)"])
        case "status": return try execute("/bin/launchctl", ["print", "\(domain)/\(Self.serviceID)"])
        default: throw UpdateFailure("Unknown service action")
        }
    }
    private func isRunning(daemon: URL) -> Bool {
        guard let status = try? service("status", daemon: daemon) else {return false}
        return status.range(of: #"(?m)^\s*pid\s*=\s*[1-9][0-9]*\s*$"#, options: .regularExpression) != nil
    }
    public func bootstrap(daemon requestedDaemon: URL? = nil) throws {
        let daemon = requestedDaemon ?? bundledDaemon
        // Opening a second/relocated app must never stop an existing daemon or
        // its terminals. Only explicit install/reconcile may replace a live service.
        if isRunning(daemon: daemon) {return}
        try installService(daemon: daemon)
    }
    private func readDaemonState() async -> DaemonIdentity? {
        if let daemonState {return await daemonState()}
        guard let token = try? String(contentsOf: data.appendingPathComponent("daemon-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {return nil}
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4318/v1/state")!); request.timeoutInterval = 1
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {return nil}
        return try? JSONDecoder().decode(DaemonIdentity.self, from: bytes)
    }
    /// Bundled daemon next to this helper inside the app.
    public var bundledDaemon: URL {helper.deletingLastPathComponent().appendingPathComponent("neura-native-core")}
    /// Written by the app right before Sparkle relaunches it after the user
    /// explicitly chose "Install and Relaunch".
    public var relaunchApproval: URL {updates.appendingPathComponent("relaunch-approved")}
    public var lastError: URL {updates.appendingPathComponent("last-error.txt")}
    public var now: () -> Date = Date.init

    private func configuredDaemon() -> String? {
        guard let bytes = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let arguments = value["ProgramArguments"] as? [String], arguments.count == 1 else {return nil}
        return arguments[0]
    }
    private func samePath(_ a: String, _ b: URL) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
    /// Consumes the approval marker. Only a recent marker counts, so an old
    /// leftover can never silently restart the daemon on a later launch.
    private func consumeApproval() -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: relaunchApproval.path),
              let written = attributes[.modificationDate] as? Date else {return false}
        try? remove(relaunchApproval)
        return now().timeIntervalSince(written) < 15 * 60
    }

    /// Brings the LaunchAgent in line with the app that was just launched.
    /// Sparkle replaces the app bundle in place, so the LaunchAgent keeps
    /// pointing at the same path while the old daemon process keeps running
    /// the replaced executable. Restarting it stops PTYs, so it only happens
    /// after an explicit approval (the relaunch marker or `approved`).
    public func reconcile(build: Int, approved requested: Bool) async throws -> ReconcileState {
        guard build > 0 else {throw UpdateFailure("Invalid build number")}
        let daemon = bundledDaemon
        let approved = consumeApproval() || requested
        guard isRunning(daemon: daemon) else {try installService(daemon: daemon); return .installed}
        // A different app copy (or a legacy runtime) owns the service: never touch it.
        guard let configured = configuredDaemon(), samePath(configured, daemon) else {return .foreign}
        let previous = await readDaemonState()
        if previous?.daemonBuild == build {return .current}
        guard approved else {return .needsRestart}
        do {
            try installService(daemon: daemon)
            var ready = false
            for _ in 0..<30 {
                if let state = await readDaemonState(), state.isNewNative(after: previous), state.daemonBuild == build {ready = true; break}
                pause(0.5)
            }
            guard ready else {throw UpdateFailure("更新後のDaemonが起動しませんでした。")}
            try remove(lastError)
            return .migrated
        } catch {
            try? directory(updates)
            try? Data(error.localizedDescription.utf8).write(to: lastError, options: .atomic)
            throw error
        }
    }
}

public enum ReconcileState: String, Codable {
    /// The service was stopped or missing and now runs the bundled daemon.
    case installed
    /// The running daemon already matches this app.
    case current
    /// The bundled daemon replaced a stale one.
    case migrated
    /// The running daemon is stale; restarting it needs the user's approval.
    case needsRestart
    /// The service belongs to another app copy or runtime and is preserved.
    case foreign
}
