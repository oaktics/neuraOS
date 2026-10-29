import AppKit
import SwiftUI
import UserNotifications

struct AgentNotificationEvent: Codable, Equatable {
    let id: String
    let sequence: Int
    let terminalId: String
    let workspaceId: String
    let provider: String
    let kind: String
    let createdAt: String
}
struct AgentNotificationPage: Codable {
    let events: [AgentNotificationEvent]
    let cursor: Int
    let more: Bool
}

// Baseline once at launch; subsequent reads retain the cursor across reconnects.
// Advance only after delivery (or an intentional skip), so a failed read can retry.
struct AgentNotificationCursor {
    private(set) var after: Int?
    mutating func baseline(_ revision: Int) {if after == nil {after = revision}}
    func pending(_ page: AgentNotificationPage) -> [AgentNotificationEvent] {
        page.events.filter {$0.sequence > (after ?? 0)}.sorted {$0.sequence < $1.sequence}
    }
    mutating func acknowledge(_ sequence: Int) {after = max(after ?? 0, sequence)}
}

@MainActor final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var cursor = AgentNotificationCursor()
    private var receiving = false
    private let openTerminal: (String) -> Void
    private var center: UNUserNotificationCenter?
    init(openTerminal: @escaping (String) -> Void) {
        self.openTerminal = openTerminal
        super.init()
        // UNUserNotificationCenter requires an app bundle; SwiftPM tests/CLI aren't one.
        guard Bundle.main.bundleURL.pathExtension == "app" else {return}
        center = UNUserNotificationCenter.current()
        center?.delegate = self
        Task {_ = try? await requestAuthorization()}
    }
    private func enabled(_ kind: String) -> Bool {
        UserDefaults.standard.object(forKey: "agentNotifications.\(kind)") as? Bool ?? true
    }
    private func requestAuthorization() async throws -> Bool {
        guard enabled("waiting") || enabled("completed"), let center else {return false}
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    func receive(_ snapshot: Snapshot, api: DaemonClient) async -> Bool {
        guard snapshot.features?.contains("terminal.notifications") == true, !receiving else {return true}
        cursor.baseline(snapshot.revision)
        receiving = true
        defer {receiving = false}
        do {
            // Drain this revision without needing a later polling tick. Yield
            // between pages so a large backlog cannot monopolize the UI.
            while !Task.isCancelled {
                let page: AgentNotificationPage = try await api.get("v1/notifications", query: ["after": String(cursor.after ?? 0)])
                for event in cursor.pending(page) {
                    if ["codex", "claude"].contains(event.provider), ["waiting", "completed"].contains(event.kind),
                       enabled(event.kind), let center {
                        let content = UNMutableNotificationContent()
                        let provider = event.provider == "claude" ? "Claude Code" : "Codex"
                        content.title = "\(provider)：\(event.kind == "waiting" ? "回答・承認待ち" : "応答が完了しました")"
                        content.body = snapshot.workspaces.first {$0.id == event.workspaceId}?.name ?? "neuraOS"
                        content.sound = .default
                        content.userInfo = ["terminalId": event.terminalId]
                        // Distinct IDs preserve rapid transitions instead of replacing a banner.
                        let request = UNNotificationRequest(identifier: "agent.\(event.id)", content: content, trigger: nil)
                        if try await requestAuthorization() {try await center.add(request)}
                    }
                    cursor.acknowledge(event.sequence)
                }
                cursor.acknowledge(page.cursor)
                if !page.more {break}
                await Task.yield()
            }
        } catch {
            NSLog("Agent notification delivery failed: %@", error.localizedDescription)
            return false
        }
        return true
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
