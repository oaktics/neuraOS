import SwiftUI
import Combine
import Darwin
import ServiceManagement
import SleepControl

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
    @Published private(set) var approvalRequired = false
    private let service = SMAppService.daemon(plistName: SleepService.plist)
    private var connection: NSXPCConnection?
    private var activationObserver: NSObjectProtocol?
    private var sessionID: UUID?
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
        refreshApproval()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {self?.refreshApproval()}
        }
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
    func refreshApproval() {
        let wasRequired = approvalRequired
        approvalRequired = service.status == .requiresApproval
        if !enabled && !runnerActive && approvalRequired {
            status = "システム設定でneuraOSのバックグラウンド実行を許可してください。"
        } else if wasRequired && service.status == .enabled && !enabled && !runnerActive {
            status = "許可済みです。この起動中のスリープ制御を有効にできます。"
        }
    }
    func openApprovalSettings() {SMAppService.openSystemSettingsLoginItems()}

    func enable() {
        guard !enabled, !runnerActive else {return}
        do {
            // Register only once. Turning sleep control off does not revoke the
            // installation approval, and launching the app never enables sleep control.
            if service.status == .notRegistered {try service.register()}
            refreshApproval()
            guard service.status == .enabled else {
                status = approvalRequired
                    ? "初回の許可が必要です。「システム設定で許可」を開いてください。"
                    : "スリープ制御サービスを登録できません。インストール済みのアプリから再度お試しください。"
                return
            }
            let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("NeuraSleepService")
            let requirement = try SleepService.requirement(for: helper)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neura-sleep-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            lease = directory.appendingPathComponent("lease")
            token = UUID().uuidString
            enabled = true; starting = true; runnerActive = true; status = "スリープ制御を開始しています…"
            let id = UUID(); sessionID = id
            monitoringActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Monitor agent work for closed-display sleep")
            heartbeat()
            guard enabled, let lease else {finish(id: id, message: status); return}
            timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {self?.heartbeat()}
            }
            RunLoop.main.add(timer!, forMode: .common)
            let connection = NSXPCConnection(machServiceName: SleepService.name, options: .privileged)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: SleepServiceProtocol.self)
            let disconnected: () -> Void = { [weak self] in
                Task { @MainActor in
                    self?.finish(id: id, message: "スリープ制御サービスとの接続が切れました。再度有効にしてください。")
                }
            }
            connection.interruptionHandler = disconnected
            connection.invalidationHandler = disconnected
            self.connection = connection
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in disconnected() } as? SleepServiceProtocol
            proxy?.run(lease: lease.path, token: token) { [weak self] result in
                Task { @MainActor in self?.finish(id: id, message: result) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.sessionID == id, self.starting else {return}
                self.finish(id: id, message: "サービスを開始できませんでした。バックグラウンド実行の許可を確認して再度お試しください。")
            }
        } catch {
            disable(); refreshApproval()
            if !approvalRequired {status = "スリープ制御の開始に失敗しました: " + error.localizedDescription}
        }
    }
    private func finish(id: UUID, message: String) {
        guard sessionID == id else {return}
        sessionID = nil
        starting = false; runnerActive = false
        disable()
        connection?.invalidate(); connection = nil
        if !message.isEmpty {status = message}
    }
    private func heartbeat() {
        guard enabled, let lease else {return}
        let fresh = Date().timeIntervalSince(lastSnapshot) < 20
        let value = Self.leaseValue(token: token, state: fresh && working ? "work" : fresh && complete ? "done" : "unknown")
        do {try value.write(to: lease, atomically: true, encoding: .utf8)}
        catch {disable(); status = "作業状態を書き込めないため解除しました。"; return}
        let file = URL(fileURLWithPath: SleepService.stateDirectory).appendingPathComponent("status")
        if let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix(token + "\n") {
            starting = false
            status = String(text.dropFirst(token.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    nonisolated static func leaseValue(token: String, state: String,
                                      awakeNanoseconds: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) -> String {
        "\(token)\n\(state)\n\(awakeNanoseconds)\n"
    }
}

struct AgentSleepFooter: View {
    @ObservedObject var controller: AgentSleepController

    private var label: String {
        if controller.stopping {return "解除中…"}
        if controller.starting {return "開始中…"}
        return controller.enabled ? "有効" : "無効"
    }

    var body: some View {
        SettingsLink {
            Label("スリープ制限：\(label)", systemImage: controller.enabled ? "moon.slash.fill" : "moon")
        }
        .buttonStyle(.plain)
        .foregroundStyle(controller.enabled ? Color.accentColor : Color.secondary)
        .help("スリープ制限：\(label)\n\(controller.status)\nクリックして設定を開く")
        .accessibilityLabel("スリープ制限：\(label)")
        .accessibilityValue(controller.status)
        .accessibilityHint("スリープ制限の設定を開きます")
    }
}

struct AgentSleepSettings: View {
    @ObservedObject var controller: AgentSleepController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("閉じたまま作業を続ける").font(.headline)
            Text("外部モニターなしでも、neuraOS内のCodex・Claude Codeが作業中はMacをスリープさせません。全作業が終了、または回答・承認待ちになると、蓋が閉じていればスリープします。")
            Text("この起動中だけ有効です。初回のみmacOSでヘルパーの許可が必要です。許可後のオン／オフでは通常、認証は不要です。バッテリー残量が10%以下、または高温の場合は解除します。通気のよい場所で使用してください。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(controller.enabled ? "無効にする" : "この起動中は有効にする") {
                    if controller.enabled {controller.disable()} else {controller.enable()}
                }.disabled(controller.stopping)
                if controller.approvalRequired {
                    Button("システム設定で許可") {controller.openApprovalSettings()}
                }
            }
            Text(controller.status).font(.callout).textSelection(.enabled)
        }.padding(24).frame(width: 520)
            .onAppear {controller.refreshApproval()}
    }
}
