import Foundation
import SwiftUI
import AppKit
import Combine
import Sparkle

/// App updates are delivered by Sparkle from the appcast served by the
/// Cloudflare update Worker. Sparkle verifies the EdDSA signature and the
/// Developer ID of the new bundle, replaces the app in place and relaunches.
///
/// The daemon is not part of Sparkle's job: after relaunch the bundled
/// `neura-updater reconcile` switches the LaunchAgent to the new daemon. That
/// restart stops PTYs, so it only happens right after the user chose
/// "Install and Relaunch" or after confirming in `AppUpdateView`.
@MainActor final class AppUpdater: NSObject, ObservableObject {
    @Published var presented = false
    @Published var busy = false
    @Published var message = ""
    /// The running daemon is older than this app and waits for the user's approval.
    @Published var daemonRestartPending = false
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet {if controller?.updater.automaticallyChecksForUpdates != automaticallyChecks {controller?.updater.automaticallyChecksForUpdates = automaticallyChecks}}
    }

    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    var currentBuild: Int {Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0}
    private var installedRelease: Bool {
        Bundle.main.bundleIdentifier == "app.neuraos.native" &&
        Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") == nil &&
        Bundle.main.object(forInfoDictionaryKey: "NeuraEndpoint") == nil
    }
    /// Release builds carry the feed and public key; development and fixture
    /// bundles never start Sparkle, so they cannot replace themselves.
    var updatesEnabled: Bool {
        installedRelease && currentBuild > 0 &&
        !(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "").isEmpty &&
        !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    }
    private static var updatesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/neuraOS/Updates")
    }

    override init() {
        super.init()
        guard updatesEnabled else {return}
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink {[weak self] in self?.canCheckForUpdates = $0}
    }

    func checkForUpdates() {
        guard let controller else {
            message = "開発・検証用アプリでは配布版のアップデートを確認できません。"; presented = true
            return
        }
        controller.checkForUpdates(nil)
    }

    /// Runs on every launch: registers the daemon on first run and finishes a
    /// Sparkle update by switching to the bundled daemon.
    func bootstrap() async {
        // Fixture/development bundles must never replace the user's LaunchAgent.
        guard installedRelease, currentBuild > 0, helperPath != nil else {return}
        await reconcile(approved: false)
    }

    func restartDaemon() {
        guard !busy else {return}
        Task {await reconcile(approved: true)}
    }

    private func reconcile(approved: Bool) async {
        busy = true
        if approved {message = "Daemonを新しいバージョンへ切り替えています…"}
        defer {busy = false}
        do {
            let data = try await run(["reconcile", String(currentBuild)] + (approved ? ["--approved"] : []))
            let state = (try? JSONDecoder().decode([String: String].self, from: data))?["state"]
            switch state {
            case "needsRestart":
                daemonRestartPending = true
                message = "neuraOSは更新されましたが、Daemonは以前のバージョンのままです。Daemonを再起動すると更新が完了します。"
                presented = true
            case "migrated" where approved:
                daemonRestartPending = false
                message = "Daemonを新しいバージョンへ切り替えました。"
                presented = true
            default:
                daemonRestartPending = false
                if presented && approved {presented = false}
                showPreviousFailure()
            }
        } catch {
            message = "Daemonの更新に失敗しました: " + error.localizedDescription
            presented = true
        }
    }

    private func showPreviousFailure() {
        let file = Self.updatesDirectory.appendingPathComponent("last-error.txt")
        guard let error = try? String(contentsOf: file, encoding: .utf8) else {return}
        try? FileManager.default.removeItem(at: file)
        message = "前回の更新に失敗しました: " + error; presented = true
    }

    private var helperPath: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("Runtime/bin/neura-updater").path,
              FileManager.default.isExecutableFile(atPath: path) else {return nil}
        return path
    }
    private func run(_ arguments: [String]) async throws -> Data {
        guard let helper = helperPath else {
            throw NSError(domain: "neuraOS.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "更新プログラムがありません。配布版を再インストールしてください。"])
        }
        return try await Task.detached(priority: .utility) {
            try UpdateProcess.run(executable: helper, arguments: arguments, timeout: nil)
        }.value
    }

    fileprivate func prepareForTermination(approved: Bool) {
        DraftCache.shared.flush()
        // SwiftUI's dismissal lock can veto termination while a sheet is attached.
        presented = false
        guard approved else {return}
        // The relaunched app restarts the daemon without asking again.
        let directory = Self.updatesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data().write(to: directory.appendingPathComponent("relaunch-approved"), options: .atomic)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {prepareForTermination(approved: false)}
    }
    /// Only called when the user chose "Install and Relaunch" — not for
    /// updates installed silently when the app quits.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {prepareForTermination(approved: true)}
    }
}

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("neuraOSのアップデート").font(.headline)
            Text(updater.message).textSelection(.enabled)
            if updater.busy {ProgressView().controlSize(.small)}
            if updater.daemonRestartPending {
                Text("再起動すると実行中のターミナル・エージェントが停止します。作業を保存してから実行してください。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(updater.daemonRestartPending ? "後で" : "閉じる") {updater.presented = false}.disabled(updater.busy)
                if updater.daemonRestartPending {
                    Button("Daemonを再起動") {updater.restartDaemon()}.disabled(updater.busy).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(updater.busy)
    }
}
