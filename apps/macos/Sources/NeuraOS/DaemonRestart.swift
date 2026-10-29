import AppKit
import Observation

/// Owns confirmation and the entire restart/reconnect interval, including offline recovery.
@MainActor @Observable final class DaemonRestart {
    private(set) var busy = false
    var message: String?

    func request(model: AppModel) {
        guard !busy else {return}
        let alert = NSAlert()
        alert.messageText = "Daemonを再起動しますか？"
        alert.informativeText = "実行中のエージェント作業とターミナルが中断される可能性があります。再起動後、アプリはDaemonへ再接続します。"
        alert.addButton(withTitle: "再起動")
        alert.addButton(withTitle: "キャンセル")
        // Reserve before the modal loop, which can reenter menu actions.
        busy = true
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        busy = false
        guard confirmed else {return}
        Task {await perform(confirmed: true, restart: {
            guard Bundle.main.bundleIdentifier == "app.neuraos.native",
                  Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") == nil,
                  Bundle.main.object(forInfoDictionaryKey: "NeuraEndpoint") == nil else {
                throw APIError(error: "restart_unavailable", message: "この開発・試験用アプリから通常のDaemonは再起動できません。")
            }
            let target = "gui/\(getuid())/app.neuraos.daemon"
            try await Task.detached {
                do {_ = try UpdateProcess.run(executable: "/bin/launchctl", arguments: ["kickstart", "-k", target], timeout: 10)}
                catch let error as NSError where error.domain == "neuraOS.Update" && error.code == 2 {
                    throw APIError(error: "restart_timeout", message: "launchctlによるDaemon再起動が10秒以内に完了しませんでした。")
                }
            }.value
            model.api.events.configure(features: nil)
            model.updateConnection(false)
        }, reconnect: {
            let snapshot: Snapshot = try await model.api.get("v1/state", timeout: 2)
            guard snapshot.protocolVersion == 1 else {
                throw APIError(error: "protocol", message: "Daemonとアプリのバージョンが一致しません。")
            }
            model.api.events.configure(features: snapshot.features)
            // A successful launchctl exit alone is never a reconnection success.
            guard !model.api.events.supported || model.api.events.connected else {return false}
            model.applySnapshot(snapshot)
            model.updateConnection(true)
            return true
        })}
    }

    func perform(confirmed: Bool, timeout: Duration = .seconds(30),
                 restart: () async throws -> Void, reconnect: () async throws -> Bool) async {
        guard confirmed, !busy else {return}
        busy = true; message = nil
        defer {busy = false}
        do {try await restart()}
        catch {message = "Daemonの再起動に失敗しました: \(error.localizedDescription)"; return}
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
        var detail = "接続の準備が完了しませんでした。"
        repeat {
            do {
                if try await reconnect() {message = "Daemonを再起動し、再接続しました。"; return}
            } catch {detail = error.localizedDescription}
            if clock.now >= deadline {break}
            do {try await Task.sleep(for: .milliseconds(200))}
            catch {break}
        } while clock.now < deadline
        message = "Daemonの再接続に失敗しました: \(detail) 再試行できます。"
    }
}
