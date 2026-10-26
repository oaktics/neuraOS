import SwiftUI
import Combine
import Darwin

/// Uses every terminal, including those in inactive workspaces. Waiting for a
/// person is not autonomous work. Unknown/disconnected state never means done.
enum AgentSleepPolicy {
    static func decision(_ terminals: [TerminalRecord], connected: Bool) -> (working: Bool, complete: Bool) {
        guard connected else {return (false, false)}
        let live = terminals.filter {($0.provider == "codex" || $0.provider == "claude") && $0.status == "running"}
        return (live.contains {$0.activity == "working"},
                live.allSatisfy {$0.activity == "idle" || $0.activity == "waiting"})
    }
}

@MainActor final class AgentSleepController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    private var runnerActive = false
    @Published private(set) var status = "無効"
    private var lease: URL?
    private var token = ""
    private var timer: Timer?
    private var monitoringActivity: NSObjectProtocol?
    private var lastSnapshot = Date.distantPast
    private var working = false
    private var complete = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {self?.disable()}
        }
    }
    func update(terminals: [TerminalRecord], connected: Bool) {
        let decision = AgentSleepPolicy.decision(terminals, connected: connected)
        working = decision.working; complete = decision.complete
        lastSnapshot = Date()
        heartbeat()
    }
    func disable() {
        enabled = false
        stopping = runnerActive
        timer?.invalidate(); timer = nil
        if let monitoringActivity {ProcessInfo.processInfo.endActivity(monitoringActivity)}
        monitoringActivity = nil
        if let lease {try? FileManager.default.removeItem(at: lease.deletingLastPathComponent())}
        lease = nil
        status = stopping ? "解除中…" : "無効"
    }
    func enable() {
        guard !enabled, !runnerActive else {return}
        // A session is intentionally not persisted across app launches.
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("NeuraSleepHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {status = "スリープ制御ヘルパーが見つかりません。アプリを再ビルドしてください。"; return}
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neura-sleep-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            lease = directory.appendingPathComponent("lease")
            token = UUID().uuidString
            enabled = true; starting = true; runnerActive = true; status = "macOSの認証を待っています…"
            monitoringActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Monitor agent work for closed-display sleep")
            heartbeat()
            guard enabled, let lease else {starting = false; runnerActive = false; stopping = false; return}
            timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {self?.heartbeat()}
            }
            RunLoop.main.add(timer!, forMode: .common)
            let command = Self.supervisedCommand(helper: helper.path, lease: lease.path, uid: getuid(), token: token)
            Task {
                let result = await Task.detached {Self.authorize(command)}.value
                self.starting = false
                self.runnerActive = false
                self.disable()
                if !result.isEmpty {self.status = result}
            }
        } catch {disable(); status = error.localizedDescription}
    }
    private func heartbeat() {
        guard enabled, let lease else {return}
        let fresh = Date().timeIntervalSince(lastSnapshot) < 20
        let value = Self.leaseValue(token: token, state: fresh && working ? "work" : fresh && complete ? "done" : "unknown")
        do {try value.write(to: lease, atomically: true, encoding: .utf8)}
        catch {disable(); status = "作業状態を書き込めないため解除しました。"; return}
        let file = URL(fileURLWithPath: "/var/run/neuraos-agent-sleep/status")
        if let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix(token + "\n") {
            starting = false
            status = String(text.dropFirst(token.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    nonisolated static func leaseValue(token: String, state: String,
                                      awakeNanoseconds: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) -> String {
        "\(token)\n\(state)\n\(awakeNanoseconds)\n"
    }
    nonisolated static func quote(_ value: String) -> String {"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"}
    nonisolated static func supervisedCommand(helper: String, lease: String, uid: uid_t, token: String) -> String {
        // The root-owned lock prevents two app copies from fighting over a
        // global power setting. The shell restores it even if the helper crashes.
        let script = """
        /bin/mkdir -m 755 /var/run/neuraos-agent-sleep || { echo "別のneuraOSがスリープ制御を使用中か、前回の復元が未完了です。" >&2; exit 73; }
        cleanup() {
          if [ -f /var/run/neuraos-agent-sleep/owned ]; then
            /usr/bin/pmset -a disablesleep 0 || return
          fi
          /bin/rm -f /var/run/neuraos-agent-sleep/owned /var/run/neuraos-agent-sleep/status
          /bin/rmdir /var/run/neuraos-agent-sleep
        }
        trap 'cleanup || exit 74' EXIT
        \(quote(helper)) \(quote(lease)) \(uid) \(quote(token))
        """
        return "/bin/sh -c " + quote(script)
    }
    nonisolated private static func authorize(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "with timeout of 31536000 seconds\n do shell script \"\(escaped)\" with administrator privileges\nend timeout"]
        let error = Pipe(); process.standardError = error; process.standardOutput = FileHandle.nullDevice
        do {try process.run(); let data = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus == 0 {return ""}
            return "スリープ制御を終了しました: " + (String(data: data, encoding: .utf8) ?? "認証またはヘルパーの起動に失敗しました。")
        } catch {return error.localizedDescription}
    }
}

struct AgentSleepSettings: View {
    @ObservedObject var controller: AgentSleepController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("閉じたまま作業を続ける").font(.headline)
            Text("外部モニターなしでも、neuraOS内のCodex・Claude Codeが作業中はMacをスリープさせません。全作業が終了、または回答・承認待ちになると、蓋が閉じていればスリープします。")
            Text("この起動中だけ有効です。有効化にはmacOSの管理者認証が必要です。バッテリー残量が10%以下、または高温の場合は解除します。通気のよい場所で使用してください。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(controller.enabled ? "無効にする" : "この起動中は有効にする") {
                    if controller.enabled {controller.disable()} else {controller.enable()}
                }.disabled(controller.stopping)
                Text(controller.status).font(.callout).textSelection(.enabled)
            }
        }.padding(24).frame(width: 520)
    }
}
