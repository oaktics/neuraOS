import Foundation
import Darwin

public struct UpdateEngine {
    public var home: URL
    public var helper: URL
    public var run: CommandRunner = NativeCommand.run
    public var pause: (TimeInterval) -> Void = {Thread.sleep(forTimeInterval: $0)}
    public var parentExists: (Int32) -> Bool = {kill($0, 0) == 0 || errno != ESRCH}
    public var launch: (String, [String]) throws -> Void = NativeCommand.launch
    public var health: (() async -> Bool)?
    private let fm = FileManager.default
    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()), helper: URL) {self.home = home; self.helper = helper}
    public var updates: URL {home.appendingPathComponent("Library/Application Support/neuraOS/Updates")}
    public var target: URL {home.appendingPathComponent("Applications/neuraOS.app")}
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
        case "install": try installService(daemon: daemon); return "neuraOS native Daemon installed."
        case "stop": return try execute("/bin/launchctl", ["bootout", "\(domain)/\(Self.serviceID)"])
        case "restart": return try execute("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(Self.serviceID)"])
        case "status": return try execute("/bin/launchctl", ["print", "\(domain)/\(Self.serviceID)"])
        default: throw UpdateFailure("Unknown service action")
        }
    }
    public func bootstrap() throws {
        let daemon = helper.deletingLastPathComponent().appendingPathComponent("neura-native-core")
        let existing = (try? Data(contentsOf: plist)).flatMap {try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]}
        if existing?["ProgramArguments"] as? [String] == [daemon.path], (try? service("status", daemon: daemon)) != nil {return}
        try installService(daemon: daemon)
    }
    public func prepare(tag: String, parentPID: Int32, latest: () async throws -> NativeRelease,
                        download: (URL) async throws -> Data) async throws {
        guard parentPID > 1 else {throw UpdateFailure("Invalid application PID")}
        let release = try await latest()
        guard release.tag == tag else {throw UpdateFailure("新しいリリースが公開されました。もう一度確認してください。")}
        try directory(updates)
        let lock = updates.appendingPathComponent("install.lock")
        do {try fm.createDirectory(at: lock, withIntermediateDirectories: false)} catch {throw UpdateFailure("更新処理が既に実行中です。")}
        let stage = updates.appendingPathComponent("stage-\(UUID().uuidString)")
        do {
            try directory(stage)
            let archive = stage.appendingPathComponent(release.name)
            if release.authenticated {
                _ = try execute("gh", ["release", "download", release.tag, "--repo", NativeRelease.repository, "--pattern", release.name, "--dir", stage.path], 600)
            } else {try await download(URL(string: release.url)!).write(to: archive)}
            try release.verify(Data(contentsOf: archive))
            _ = try execute("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path], 120)
            let app = stage.appendingPathComponent("neuraOS.app")
            _ = try execute("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], 120)
            // Release artifacts must retain Developer ID / Gatekeeper acceptance.
            _ = try execute("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], 120)
            let info = app.appendingPathComponent("Contents/Info.plist")
            let identity = try execute("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", info.path]).trimmingCharacters(in: .whitespacesAndNewlines)
            let build = try execute("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleVersion", info.path]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard identity == "app.neuraos.native", build == String(release.build) else {throw UpdateFailure("アプリのバージョン情報が一致しません。")}
            for name in ["neura-native-core", "neura-updater"] {
                guard fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/Resources/Runtime/bin/\(name)").path) else {throw UpdateFailure("native runtimeがありません。")}
            }
            let installer = stage.appendingPathComponent("neura-updater")
            try fm.copyItem(at: helper, to: installer)
            try launch(installer.path, ["apply", stage.path, String(parentPID)])
        } catch {
            try? remove(stage); try? remove(lock)
            throw error
        }
    }
    private func healthy() async -> Bool {
        if let health {return await health()}
        guard let token = try? String(contentsOf: data.appendingPathComponent("daemon-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {return false}
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4318/v1/state")!); request.timeoutInterval = 1
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {return false}
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    public func apply(stage: URL, parentPID: Int32) async throws {
        guard parentPID > 1, stage.deletingLastPathComponent().resolvingSymlinksInPath() == updates.resolvingSymlinksInPath(),
              stage.lastPathComponent.hasPrefix("stage-") else {throw UpdateFailure("Invalid update stage")}
        let backup = URL(fileURLWithPath: target.path + ".previous")
        var oldPlist: Data?, moved = false, installed = false, serviceChanged = false
        defer {try? remove(updates.appendingPathComponent("install.lock")); try? remove(stage)}
        do {
            var exited = false
            for _ in 0..<120 {if !parentExists(parentPID) {exited = true; break}; pause(0.5)}
            guard exited else {throw UpdateFailure("アプリが終了しなかったため更新を中止しました。")}
            if fm.fileExists(atPath: plist.path) {
                oldPlist = try Data(contentsOf: plist)
                let savedPlist = updates.appendingPathComponent("previous-launch-agent.plist")
                try oldPlist!.write(to: savedPlist, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: savedPlist.path)
            }
            try directory(target.deletingLastPathComponent())
            try remove(backup)
            if fm.fileExists(atPath: target.path) {try fm.moveItem(at: target, to: backup); moved = true}
            try fm.moveItem(at: stage.appendingPathComponent("neuraOS.app"), to: target); installed = true
            serviceChanged = true
            try installService(daemon: target.appendingPathComponent("Contents/Resources/Runtime/bin/neura-native-core"))
            var ready = false
            for _ in 0..<30 {if await healthy() {ready = true; break}; pause(0.5)}
            guard ready else {throw UpdateFailure("更新後のDaemonが起動しませんでした。")}
            try remove(updates.appendingPathComponent("last-error.txt"))
            _ = try execute("/usr/bin/open", [target.path])
        } catch {
            if serviceChanged {_ = try? run("/bin/launchctl", ["bootout", "\(domain)/\(Self.serviceID)"], 5)}
            // Do not erase the backup if restoration itself fails: preserve data.
            if installed {try remove(target)}
            if moved {try fm.moveItem(at: backup, to: target)}
            if serviceChanged, let oldPlist {
                try oldPlist.write(to: plist, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
                _ = try? run("/bin/launchctl", ["bootstrap", domain, plist.path], 5)
            } else if serviceChanged {try remove(plist)}
            try directory(updates)
            try Data(error.localizedDescription.utf8).write(to: updates.appendingPathComponent("last-error.txt"), options: .atomic)
            if moved {_ = try? run("/usr/bin/open", [target.path], 30)}
            throw error
        }
    }
}
