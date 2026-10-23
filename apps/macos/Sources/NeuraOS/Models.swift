import Foundation
import SwiftUI

struct Project: Codable, Identifiable {let id: String; let name: String; let path: String; let isGit: Bool?; var supportsGit: Bool {isGit != false}}
struct Workspace: Codable, Identifiable, Hashable {let id: String; let projectId: String; let name: String; let path: String; let branch: String; let kind: String; var supportsGit: Bool {kind != "folder"}}
struct TerminalRecord: Codable, Identifiable {let id: String; let workspaceId: String; let provider: String; let status: String; let cols: Int; let rows: Int; var activity: String? = nil}
struct Snapshot: Codable {
    var protocolVersion = 1; var hostName = "このMac"; var revision = 0
    var features: [String]?
    var supportsMultipleTerminals: Bool {protocolVersion == 1 && features?.contains("terminal.multiple") == true}
    var supportsGitHub: Bool {protocolVersion == 1 && features?.contains("github") == true}
    var projects: [Project] = []; var workspaces: [Workspace] = []; var terminals: [TerminalRecord] = []
}
struct FileEntry: Codable, Identifiable {var id: String {path}; let name: String; let path: String; let isDirectory: Bool}
struct DirectoryListing: Codable {let path: String; let entries: [FileEntry]}
struct FileContent: Codable, Equatable {let path: String; let content: String; let hash: String}
struct Change: Codable, Identifiable {var id: String {path}; let path: String; let status: String}
struct GitStatus: Codable {var branch: String = ""; var changes: [Change] = []}
struct Diff: Codable {let path: String; let content: String}
struct TerminalChunk: Codable {let data: String; let cols: Int?; let rows: Int?}
struct TerminalOutput: Codable {let data: String; let chunks: [TerminalChunk]; let cursor: Int; let more: Bool; let status: String; let cols: Int; let rows: Int}
struct APIError: Codable, Error, LocalizedError {let error: String; let message: String; var errorDescription: String? {message}}
struct OK: Codable {let ok: Bool}

final class DaemonClient {
    let endpoint: URL
    let dataDirectory: URL
    let clientId: String
    private let session: URLSession
    init() {
        clientId = UserDefaults.standard.string(forKey: "daemonClientId") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(clientId, forKey: "daemonClientId")
        endpoint = URL(string: Bundle.main.object(forInfoDictionaryKey: "NeuraEndpoint") as? String ?? "http://127.0.0.1:4318")!
        dataDirectory = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") as? String ?? NSHomeDirectory() + "/Library/Application Support/neuraOS/Developer")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }
    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {try await request(path, query: query, timeout: path.hasSuffix("/github") ? 180 : path.hasSuffix("/checks") ? 90 : 15)}
    func command<T: Decodable>(_ command: [String: Any]) async throws -> T {
        // One operation ID per user action. Never automatically resend uncertain terminal input.
        try await request("v1/commands", body: ["operationId": UUID().uuidString.lowercased(), "command": command], timeout: ((command["type"] as? String)?.hasPrefix("github.") == true || command["type"] as? String == "workspace.delete") ? 240 : 15)
    }
    private func request<T: Decodable>(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> T {
        var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query.sorted(by: {$0.key < $1.key}).map {URLQueryItem(name: $0.key, value: $0.value)}
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timeout
        let token = try String(contentsOf: dataDirectory.appendingPathComponent("daemon-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body)}
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw (try? JSONDecoder().decode(APIError.self, from: data)) ?? APIError(error: "connection", message: "Daemonへの接続に失敗しました。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor final class AppModel: ObservableObject {
    let api = DaemonClient()
    @Published var state = Snapshot()
    @Published var selectedId: String? = UserDefaults.standard.string(forKey: "selectedWorkspace")
    @Published var connected = false
    @Published var providerUsage: [ProviderUsage] = []
    @Published var usageFailed = false
    @Published var error: String?
    @Published var busy = false
    @Published var showNewWorkspace = false
    @Published var showNewSpace = false
    @Published var sidebarSpaces: SidebarSpaces = {
        if let data = UserDefaults.standard.data(forKey: "sidebarSpaces"),
           let saved = try? JSONDecoder().decode(SidebarSpaces.self, from: data), !saved.spaces.isEmpty {return saved}
        return SidebarSpaces()
    }() {
        didSet {if let data = try? JSONEncoder().encode(sidebarSpaces) {UserDefaults.standard.set(data, forKey: "sidebarSpaces")}}
    }
    var visibleProjects: [Project] {state.projects.filter {sidebarSpaces.owner(of: $0.id) == sidebarSpaces.active.id}}
    var visibleWorkspaces: [Workspace] {state.workspaces.filter {sidebarSpaces.owner(of: $0.projectId) == sidebarSpaces.active.id}}
    func createSpace(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {return}
        sidebarSpaces.create(name: name)
        select(nil)
    }
    func switchSpace(_ id: String) {
        guard sidebarSpaces.spaces.contains(where: {$0.id == id}) else {return}
        sidebarSpaces.activeId = id
        let saved = sidebarSpaces.active.selectedWorkspaceId
        select(visibleWorkspaces.first(where: {$0.id == saved})?.id ?? visibleWorkspaces.first?.id)
    }
    func moveProject(_ projectId: String, to spaceId: String) {
        guard sidebarSpaces.spaces.contains(where: {$0.id == spaceId}) else {return}
        sidebarSpaces.projectSpaces[projectId] = spaceId
        switchSpace(sidebarSpaces.active.id)
    }
    @Published var showSidebar = UserDefaults.standard.object(forKey: "showLeftSidebar") as? Bool ?? true {
        didSet {UserDefaults.standard.set(showSidebar, forKey: "showLeftSidebar")}
    }
    @Published var showInspector = UserDefaults.standard.object(forKey: "showRightSidebar") as? Bool ?? true {
        didSet {UserDefaults.standard.set(showInspector, forKey: "showRightSidebar")}
    }
    @Published var openedIds: Set<String> = []
    private var polling: Task<Void, Never>?
    var gitProjects: [Project] {visibleProjects.filter { $0.supportsGit }}
    var selected: Workspace? {state.workspaces.first {$0.id == selectedId}}
    var supportsGitHub: Bool {connected && state.supportsGitHub}
    init(startPolling: Bool = true) {
        guard startPolling else {return}
        polling = Task { [weak self] in
            while !Task.isCancelled {await self?.refresh(); try? await Task.sleep(for: .seconds(1))}
        }
    }
    func refresh() async {
        do {
            let next: Snapshot = try await api.get("v1/state")
            guard next.protocolVersion == 1 else {throw APIError(error: "protocol", message: "Daemonとアプリのバージョンが一致しません。")}
            // A daemon upgrade can change features without changing stored data/revision.
            if next.revision != state.revision || next.features != state.features || !connected {state = next}
            openedIds.formIntersection(Set(state.workspaces.map(\.id)))
            connected = true
            if (selectedId != nil || !visibleWorkspaces.isEmpty), !visibleWorkspaces.contains(where: {$0.id == selectedId}) {
                let saved = sidebarSpaces.active.selectedWorkspaceId
                select(visibleWorkspaces.first(where: {$0.id == saved})?.id ?? visibleWorkspaces.first?.id)
            }
            if sidebarSpaces.active.selectedWorkspaceId != selectedId {sidebarSpaces.remember(selectedId)}
            if let selectedId, !openedIds.contains(selectedId) {openedIds.insert(selectedId)}
        } catch {connected = false}
    }
    func select(_ id: String?) {
        if let workspace = state.workspaces.first(where: {$0.id == id}) {sidebarSpaces.activeId = sidebarSpaces.owner(of: workspace.projectId)}
        sidebarSpaces.remember(id)
        selectedId = id; if let id {openedIds.insert(id)}; UserDefaults.standard.set(id, forKey: "selectedWorkspace")}
    func report(_ error: Error) {self.error = error.localizedDescription}
    func refreshUsage() async {
        do {
            let response: ProviderUsageResponse = try await api.get("v1/usage")
            providerUsage = response.providers
            usageFailed = false
        } catch {usageFailed = true; providerUsage = []}
    }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "作業するフォルダを選択（Gitは不要です）"; panel.prompt = "追加"
        guard panel.runModal() == .OK, let path = panel.url?.path else {return}
        let targetSpaceId = sidebarSpaces.active.id
        busy = true
        Task {defer {busy = false}; do {
            let project: Project = try await api.command(["type": "project.add", "path": path])
            sidebarSpaces.projectSpaces[project.id] = targetSpaceId
            await refresh(); select(state.workspaces.first {$0.projectId == project.id}?.id)
        } catch {report(error)}}
    }
    func createWorkspace(projectId: String, base: String) async {
        busy = true; defer {busy = false}
        do {let workspace: Workspace = try await api.command(["type": "workspace.create", "projectId": projectId, "baseRef": base]); await refresh(); select(workspace.id); showNewWorkspace = false} catch {report(error)}
    }
    func deleteWorkspace(_ workspace: Workspace, discardChanges: Bool = false) async {
        guard workspace.kind == "worktree", !busy else {return}
        busy = true; defer {busy = false}
        do {
            let _: OK = try await api.command(["type": "workspace.delete", "workspaceId": workspace.id, "discardChanges": discardChanges])
            await refresh()
        } catch {report(error)}
    }
    func openTerminal(_ workspace: Workspace, provider: String, resume: Bool = false) async -> TerminalRecord? {
        busy = true; defer {busy = false}
        do {
            // Check before sending: concurrent opens against legacy daemons can return the same PTY.
            guard state.supportsMultipleTerminals else {
                throw APIError(error: "daemon_update_required", message: "Daemonの更新が必要です。実行中の作業を終えてから pnpm service restart を実行してください。")
            }
            let terminal: TerminalRecord = try await api.command(["type": "terminal.open", "workspaceId": workspace.id, "provider": provider, "resume": resume])
            await refresh(); return terminal
        } catch {report(error); return nil}
    }
    @discardableResult func stopTerminal(_ terminal: TerminalRecord) async -> Bool {
        do {let _: OK = try await api.command(["type": "terminal.stop", "terminalId": terminal.id]); await refresh(); return true} catch {report(error); return false}
    }
    func terminal(id: String?) -> TerminalRecord? {state.terminals.first {$0.id == id}}
}


struct ProviderUsageResponse: Decodable {let providers: [ProviderUsage]}
struct UsageWindow: Decodable {
    let label: String
    let usedPercent: Double
    let resetsAt: String?
    var percentage: String {String(format: "%.0f%%", usedPercent)}
    func resetCountdown(at now: Date) -> String? {
        guard let resetsAt, let reset = ProviderUsage.date(resetsAt) else {return nil}
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else {return "更新待ち"}
        let minutes = Int(ceil(seconds / 60))
        if minutes >= 1440 {return "\(minutes / 1440)d \((minutes % 1440) / 60)h"}
        if minutes >= 60 {return "\(minutes / 60)h \(minutes % 60)m"}
        return "\(minutes)m"
    }
}
struct ProviderUsage: Decodable, Identifiable {
    var id: String {provider}
    let provider: String
    let status: String
    let windows: [UsageWindow]
    let checkedAt: String
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {return date}
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    func isStale(at now: Date) -> Bool {
        guard let date = Self.date(checkedAt) else {return true}
        return now.timeIntervalSince(date) > 150
    }
    var statusLabel: String {
        switch status {
        case "signed_out": return "ログインが必要"
        case "unsupported": return "情報なし"
        default: return "取得できません"
        }
    }
    var details: String {
        var lines = ["アカウント共通の利用枠の使用率（約1分ごとに更新）"]
        for window in windows {
            let reset = window.resetsAt.flatMap(Self.date).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "不明"
            lines.append("\(window.label): \(window.percentage) 使用・リセット \(reset)")
        }
        if let date = Self.date(checkedAt) {lines.append("確認: \(date.formatted(date: .omitted, time: .standard))")}
        if status == "signed_out" {lines.append("CLIでログインを確認してください。")}
        return lines.joined(separator: "\n")
    }
}
