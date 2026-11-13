import SwiftUI
import Combine
import Darwin
import IOKit
import ServiceManagement
import SleepControl

/// Uses every terminal, including those in inactive workspaces. Waiting for a
/// person is not autonomous work. Unknown/disconnected state never means done.
enum AgentSleepPolicy {
    /// A finished turn may leave shells, subagents or wakeups that will resume
    /// the agent. They count as work, but only for a bounded time: a forgotten
    /// dev server must not keep a closed Mac awake indefinitely.
    static let backgroundLimit: TimeInterval = 2 * 60 * 60

    static func decision(_ terminals: [TerminalRecord], connected: Bool) -> (working: Bool, background: Bool, complete: Bool) {
        guard connected else {return (false, false, false)}
        let live = terminals.filter {($0.provider == "codex" || $0.provider == "claude") && $0.status == "running"}
        let settled: (TerminalRecord) -> Bool = {$0.activity == "idle" || $0.activity == "waiting"}
        return (live.contains {$0.activity == "working"},
                live.contains {settled($0) && $0.background == true},
                live.allSatisfy(settled))
    }

    /// `backgroundFor` is how long only background work has remained, if any.
    static func leaseState(fresh: Bool, working: Bool, backgroundFor: TimeInterval?, complete: Bool) -> String {
        guard fresh else {return "unknown"}
        if working || backgroundFor.map({$0 < backgroundLimit}) == true {return "work"}
        return complete ? "done" : "unknown"
    }
}

enum LidState {
    static var closed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {return nil}
        defer {IOObjectRelease(service)}
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
}

/// Suppressing lid-close sleep also suppresses the lock that sleep implies.
/// Locking does not suspend processes, so agents keep running.
enum ScreenLock {
    static let preferenceKey = "agentSleepLockOnLidClose"
    static var enabled: Bool {UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true}
    static func lock() {
        typealias Function = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: Function.self)()
            return
        }
        // Falls back to the user's "require password after display off" setting.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }
}

@MainActor final class AgentSleepController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published private(set) var repairing = false
    @Published private(set) var startFailed = false
    private var runnerActive = false
    @Published private(set) var approvalRequired = false
    private var registrationError: Error?
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
    private var backgroundSince: TimeInterval?
    private var lidClosed: Bool?
    /// State arrives by push; without changes nothing would confirm that the
    /// last snapshot still holds. Ask the owner to re-read it while enabled.
    var requestRefresh: (() -> Void)?
    nonisolated static let refreshInterval: TimeInterval = 8
    nonisolated static let freshness: TimeInterval = 20
    private var observer: NSObjectProtocol?

    /// On by default. The user's choice persists across launches; failures,
    /// safety releases and quitting never change it.
    nonisolated static let preferenceKey = "agentSleepWanted"
    nonisolated static func wanted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }
    private var launchStartPending = false

    init() {
        refreshApproval()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {self?.refreshApproval(); self?.startIfWanted()}
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {self?.disable()}
        }
    }
    func update(terminals: [TerminalRecord], connected: Bool) {
        let decision = AgentSleepPolicy.decision(terminals, connected: connected)
        working = decision.working; complete = decision.complete
        if decision.working || !decision.background {backgroundSince = nil}
        else if backgroundSince == nil {backgroundSince = ProcessInfo.processInfo.systemUptime}
        lastSnapshot = Date()
        heartbeat()
    }
    func setWanted(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.preferenceKey)
        launchStartPending = false
        if value {enable()} else {disable()}
    }
    /// Called once at app launch. Starting must never raise a macOS approval
    /// prompt by itself, so an unapproved service waits until the user returns
    /// from System Settings. After the first attempt, only the user restarts it.
    func startAtLaunch() {launchStartPending = true; startIfWanted()}
    private func startIfWanted() {
        guard launchStartPending, Self.wanted(), !enabled, !runnerActive, service.status == .enabled else {return}
        launchStartPending = false
        enable()
    }
    func disable() {
        enabled = false
        stopping = runnerActive
        timer?.invalidate(); timer = nil
        if let monitoringActivity {ProcessInfo.processInfo.endActivity(monitoringActivity)}
        monitoringActivity = nil
        if let lease {try? FileManager.default.removeItem(at: lease.deletingLastPathComponent())}
        lease = nil; lidClosed = nil
        status = stopping ? "解除中…" : "無効"
    }
    func refreshApproval() {
        let wasRequired = approvalRequired
        let current = service.status
        if current == .enabled {registrationError = nil}
        approvalRequired = SleepServiceRegistration.needsApproval(status: current, error: registrationError)
        if !enabled && !runnerActive && approvalRequired {
            status = "システム設定でneuraOSのバックグラウンド実行を許可してください。"
        } else if wasRequired && service.status == .enabled && !enabled && !runnerActive {
            status = "許可済みです。スリープ制御を有効にできます。"
        }
    }
    func openApprovalSettings() {SMAppService.openSystemSettingsLoginItems()}

    func repairRegistration() {
        guard !enabled, !runnerActive, !repairing else {return}
        startFailed = false
        repairing = true
        status = "スリープ制御サービスの登録を修復しています…"
        Task {
            defer {repairing = false}
            do {
                try await SleepServiceRegistration.repair(
                    status: {self.service.status},
                    validate: {try SleepServiceRegistration.validateBundle(at: Bundle.main.bundleURL)},
                    unregister: {try await self.service.unregister()},
                    register: {try self.service.register()})
                refreshApproval()
                status = approvalRequired
                    ? "システム設定で許可してから、再度有効にしてください。"
                    : service.status == .enabled
                        ? "登録を更新しました。「有効にする」で再度お試しください。"
                        : "サービスの登録を確認できません。アプリを再起動して再度お試しください。"
            } catch {
                registrationError = error
                refreshApproval()
                if !approvalRequired {
                    let detail = error as NSError
                    status = "登録の修復に失敗しました: \(detail.localizedDescription)（\(detail.domain): \(detail.code)）"
                }
            }
        }
    }

    func enable() {
        guard !enabled, !runnerActive, !repairing else {return}
        startFailed = false
        do {
            // Register only once. Turning sleep control off does not revoke the
            // installation approval. Launch starts it only when already approved.
            let registrationStatus = try SleepServiceRegistration.prepare(
                status: {self.service.status},
                validate: {try SleepServiceRegistration.validateBundle(at: Bundle.main.bundleURL)},
                register: {try self.service.register()})
            refreshApproval()
            guard registrationStatus == .enabled else {
                startFailed = !approvalRequired
                status = approvalRequired
                    ? "初回の許可が必要です。「システム設定で許可」を開いてください。"
                    : "スリープ制御サービスの登録を確認できません（状態: \(registrationStatus.rawValue)）。再度有効にしてください。"
                return
            }
            let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("NeuraSleepService")
            let requirement = try SleepService.requirement(for: helper, requireHardenedRuntime: true)
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
                self.finish(id: id, message: "サービスを開始できませんでした。許可済みの場合は、設定の「サービス登録を修復」をお試しください。")
            }
        } catch {
            registrationError = error
            disable(); refreshApproval()
            startFailed = !approvalRequired
            if !approvalRequired {
                let detail = error as NSError
                status = "スリープ制御の開始に失敗しました: \(detail.localizedDescription)（\(detail.domain): \(detail.code)）"
            }
        }
    }
    private func finish(id: UUID, message: String) {
        guard sessionID == id else {return}
        startFailed = starting && enabled && !message.isEmpty
        sessionID = nil
        starting = false; runnerActive = false
        disable()
        connection?.invalidate(); connection = nil
        if !message.isEmpty {status = message}
    }
    private func heartbeat() {
        guard enabled, let lease else {return}
        let age = Date().timeIntervalSince(lastSnapshot)
        if age >= Self.refreshInterval {requestRefresh?()}
        let backgroundFor = backgroundSince.map {ProcessInfo.processInfo.systemUptime - $0}
        let state = AgentSleepPolicy.leaseState(fresh: age < Self.freshness, working: working, backgroundFor: backgroundFor, complete: complete)
        do {try Self.leaseValue(token: token, state: state).write(to: lease, atomically: true, encoding: .utf8)}
        catch {disable(); status = "作業状態を書き込めないため解除しました。"; return}
        let closed = LidState.closed
        if state == "work", closed == true, lidClosed == false, ScreenLock.enabled {ScreenLock.lock()}
        lidClosed = closed
        let file = URL(fileURLWithPath: SleepService.stateDirectory).appendingPathComponent("status")
        if let text = try? String(contentsOf: file, encoding: .utf8), text.hasPrefix(token + "\n") {
            starting = false
            status = String(text.dropFirst(token.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if state == "work", !working, status.hasPrefix("作業中") {
                status = "バックグラウンド処理中：蓋を閉じても継続します（最長2時間）"
            }
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
        if controller.repairing {return "修復中…"}
        if controller.stopping {return "解除中…"}
        if controller.starting {return "開始中…"}
        if controller.approvalRequired {return "許可が必要"}
        if controller.startFailed {return "開始失敗"}
        return controller.enabled ? "有効" : "無効"
    }

    private var actionHint: String {
        if controller.enabled {return "クリックしてスリープ制限を無効にします"}
        if controller.approvalRequired {return "クリックしてシステム設定で許可します"}
        return "クリックしてスリープ制限を有効にします"
    }

    var body: some View {
        Button {
            if controller.enabled {controller.setWanted(false)}
            else if controller.approvalRequired {controller.openApprovalSettings()}
            else {controller.setWanted(true)}
        } label: {
            Label("スリープ制限：\(label)", systemImage: controller.enabled ? "moon.slash.fill" : "moon")
        }
        .buttonStyle(.plain)
        .disabled(controller.starting || controller.stopping || controller.repairing)
        .foregroundStyle(controller.enabled ? Color.accentColor : Color.secondary)
        .help("スリープ制限：\(label)\n\(controller.status)\n\(actionHint)")
        .accessibilityLabel("スリープ制限：\(label)")
        .accessibilityValue(controller.status)
        .accessibilityHint(actionHint)
    }
}

struct AgentSleepSettings: View {
    @ObservedObject var controller: AgentSleepController
    @AppStorage(ScreenLock.preferenceKey) private var lockOnLidClose = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("閉じたまま作業を続ける").font(.headline)
            Text("外部モニターなしでも、neuraOS内のCodex・Claude Codeが作業中はMacをスリープさせません。全作業が終了、または回答・承認待ちになると、蓋が閉じていればスリープします。ターン終了後もバックグラウンドのシェルやサブエージェントが残っている間は、最長2時間継続します。")
            Toggle("継続中に蓋を閉じたら画面をロックする", isOn: $lockOnLidClose)
            Text("既定で有効です。無効にすると次回の起動後も無効のままです。初回のみmacOSでヘルパーの許可が必要です。許可後のオン／オフでは通常、認証は不要です。バッテリー残量が10%以下、または高温の場合は解除します。通気のよい場所で使用してください。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(controller.enabled ? "無効にする" : "有効にする") {
                    controller.setWanted(!controller.enabled)
                }.disabled(controller.starting || controller.stopping || controller.repairing)
                if controller.approvalRequired {
                    Button("システム設定で許可") {controller.openApprovalSettings()}
                }
            }
            if !controller.enabled && !controller.approvalRequired {
                Button("サービス登録を修復") {controller.repairRegistration()}
                    .disabled(controller.starting || controller.stopping || controller.repairing)
            }
            Text(controller.status).font(.callout).textSelection(.enabled)
        }.padding(24).frame(width: 520)
            .onAppear {controller.refreshApproval()}
    }
}
