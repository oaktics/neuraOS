import Foundation
import SwiftUI
import AppKit

struct NativeRelease: Decodable {
    let tag: String
    let build: Int
}

@MainActor final class AppUpdater: ObservableObject {
    @Published var presented = false
    @Published var busy = false
    @Published private(set) var restarting = false
    @Published var message = ""
    @Published var release: NativeRelease?
    var currentBuild: Int {Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0}

    func bootstrap() async {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("Runtime/bin/node").path) else {return}
        do {_ = try await run(["bootstrap"], bundledScript: true)}
        catch {message = error.localizedDescription; presented = true}
        let errorFile = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/neuraOS/Updates/last-error.txt")
        if let error = try? String(contentsOf: errorFile, encoding: .utf8) {
            message = "前回の更新に失敗しました: " + error; presented = true
        }
    }

    func check() {
        guard !busy else {return}
        presented = true; busy = true; release = nil; message = "アップデートを確認しています…"
        Task {
            do {
                let data = try await run(["check"])
                let candidate = try JSONDecoder().decode(NativeRelease.self, from: data)
                if candidate.build > currentBuild {
                    release = candidate
                    message = "新しいバージョン（\(candidate.tag)）を利用できます。"
                } else {message = "最新バージョンです。"}
            } catch {message = error.localizedDescription}
            busy = false
        }
    }

    func install() {
        guard let release, !busy else {return}
        busy = true; message = "ダウンロードして検証しています。完了するとアプリを再起動します…"
        Task {
            do {
                _ = try await run(["prepare", release.tag, String(ProcessInfo.processInfo.processIdentifier)])
                DraftCache.shared.flush()
                // SwiftUI's dismissal lock can veto application termination while
                // the update sheet is attached. Unlock and dismiss it first.
                restarting = true
                presented = false
                try await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
                // terminate can return if another window cancels termination.
                // Wait for the installer to abandon its 60-second exit wait before
                // allowing another install, so two installers cannot race.
                try await Task.sleep(for: .seconds(65))
                restarting = false
                busy = false
                message = "アプリを終了できなかったため更新を中止しました。作業を保存し、アプリを終了してから再度お試しください。"
                presented = true
            } catch {message = error.localizedDescription; restarting = false; busy = false; presented = true}
        }
    }

    private func run(_ arguments: [String], bundledScript: Bool = false) async throws -> Data {
        guard let resources = Bundle.main.resourceURL else {throw updateError("更新プログラムがありません。")}
        let bundled = resources.appendingPathComponent("Runtime/bin/node").path
        let node = [bundled, "/opt/homebrew/bin/node", "/usr/local/bin/node"].first {FileManager.default.isExecutableFile(atPath: $0)}
        guard let node else {throw updateError("更新にはNode.js 24が必要です。初回は配布版をインストールしてください。")}
        let script = resources.appendingPathComponent(bundledScript ? "Runtime/scripts/native/release/update.mjs" : "update.mjs").path
        return try await Task.detached(priority: .utility) {
            try UpdateProcess.run(executable: node, arguments: [script] + arguments,
                                  timeout: ["prepare", "bootstrap"].contains(arguments.first ?? "") ? nil : 90)
        }.value
    }
    private func updateError(_ text: String) -> NSError {NSError(domain: "neuraOS.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: text])}
}

struct AppUpdateView: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("neuraOSのアップデート").font(.headline)
            Text(updater.message).textSelection(.enabled)
            if updater.busy {ProgressView().controlSize(.small)}
            if updater.release != nil {
                Text("適用するとDaemonも再起動し、実行中のターミナル・エージェントが停止します。作業を保存してから更新してください。アプリはホームフォルダのApplicationsへインストールされます。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("閉じる") {updater.presented = false}.disabled(updater.busy)
                if updater.release != nil {Button("更新して再起動") {updater.install()}.disabled(updater.busy)}
                else {Button("再確認") {updater.check()}.disabled(updater.busy)}
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(updater.busy && !updater.restarting)
    }
}
