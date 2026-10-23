import AppKit
import SwiftUI
import UserNotifications

struct AgentNotificationEvent: Codable, Equatable {
    let id: String
    let kind: String
    let createdAt: String
}

// The first snapshot is a baseline, so launching the app never replays old work.
// Keep event IDs across reconnects, even if a transient snapshot omits a terminal.
struct AgentNotificationCursor {
    private var initialized = false
    private var seen: [String: String] = [:]
    mutating func consume(_ terminals: [TerminalRecord]) -> [TerminalRecord] {
        defer {initialized = true}
        return terminals.filter {terminal in
            guard let event = terminal.notification else {return false}
            let previous = seen.updateValue(event.id, forKey: terminal.id)
            return initialized && previous != event.id && ["codex", "claude"].contains(terminal.provider)
                && ["waiting", "completed"].contains(event.kind)
        }
    }
}

@MainActor final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var cursor = AgentNotificationCursor()
    private let openTerminal: (String) -> Void
    private var center: UNUserNotificationCenter?
    init(openTerminal: @escaping (String) -> Void) {
        self.openTerminal = openTerminal
        super.init()
        // UNUserNotificationCenter requires an app bundle; SwiftPM tests/CLI aren't one.
        guard Bundle.main.bundleURL.pathExtension == "app" else {return}
        center = UNUserNotificationCenter.current()
        center?.delegate = self
        Task {await requestAuthorization()}
    }
    private func enabled(_ kind: String) -> Bool {
        UserDefaults.standard.object(forKey: "agentNotifications.\(kind)") as? Bool ?? true
    }
    private func requestAuthorization() async {
        guard enabled("waiting") || enabled("completed"), let center else {return}
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch {NSLog("Agent notification authorization failed: %@", error.localizedDescription)}
    }
    func receive(_ snapshot: Snapshot) {
        for terminal in cursor.consume(snapshot.terminals) {
            guard let event = terminal.notification, enabled(event.kind), let center else {continue}
            let content = UNMutableNotificationContent()
            let provider = terminal.provider == "claude" ? "Claude Code" : "Codex"
            content.title = "\(provider)：\(event.kind == "waiting" ? "回答・承認待ち" : "応答が完了しました")"
            content.body = snapshot.workspaces.first {$0.id == terminal.workspaceId}?.name ?? "neuraOS"
            content.sound = .default
            content.userInfo = ["terminalId": terminal.id]
            // Replace this terminal's previous banner rather than accumulating stale requests.
            let request = UNNotificationRequest(identifier: "agent.\(terminal.id)", content: content, trigger: nil)
            Task {
                await requestAuthorization()
                do {try await center.add(request)}
                catch {NSLog("Agent notification delivery failed: %@", error.localizedDescription)}
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["terminalId"] as? String
        Task { @MainActor in
            if let id {self.openTerminal(id)}
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: {$0.canBecomeMain})?.makeKeyAndOrderFront(nil)
            completionHandler()
        }
    }
}

struct AgentNotificationCommands: Commands {
    @AppStorage("agentNotifications.waiting") private var waiting = true
    @AppStorage("agentNotifications.completed") private var completed = true
    var body: some Commands {
        CommandMenu("通知") {
            Toggle("回答・承認待ちを通知", isOn: $waiting)
            Toggle("応答完了を通知", isOn: $completed)
            Divider()
            Button("macOSの通知設定を開く…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {NSWorkspace.shared.open(url)}
            }
        }
    }
}
