import Foundation
import SwiftUI
import Combine
import Observation

enum WorkspaceAction: Equatable {
    case add(String), close, move(Int), select(Int), inspector(String)
}

struct WorkspaceCommandRequest {
    let workspaceId: String
    let action: WorkspaceAction
}

struct Project: Codable, Identifiable, Equatable {let id: String; let name: String; let path: String; let isGit: Bool?; var folderless: Bool? = nil; var worktreeStartup: [String]? = nil; var worktreeSetup: String? = nil; var defaultConversationProvider: String? = nil; var defaultDelegationProvider: String? = nil; var inheritedProvider: String {let agents = Set((worktreeStartup ?? []).filter {["codex", "claude"].contains($0)}); return agents.count == 1 ? agents.first! : "codex"}; var conversationProvider: String {defaultConversationProvider ?? inheritedProvider}; var delegationProvider: String {defaultDelegationProvider ?? inheritedProvider}; var supportsGit: Bool {folderless != true && isGit != false}}
struct WorktreeSetup: Codable, Hashable {let status: String; let script: String; let output: String; var error: String?}
struct Workspace: Codable, Identifiable, Hashable {let id: String; let projectId: String; let name: String; let path: String; let branch: String; let kind: String; var setup: WorktreeSetup? = nil; var supportsGit: Bool {kind == "root" || kind == "worktree"}; var hasFolder: Bool {kind != "scratch"}}
struct TerminalRecord: Codable, Identifiable, Equatable {let id: String; let workspaceId: String; let provider: String; let status: String; let cols: Int; let rows: Int; var activity: String? = nil; var sessionName: String? = nil}
struct Snapshot: Codable {
    var protocolVersion = 1; var hostName = "このMac"; var revision = 0
    var features: [String]?
    var supportsMultipleTerminals: Bool {protocolVersion == 1 && features?.contains("terminal.multiple") == true}
    var supportsGitHub: Bool {protocolVersion == 1 && features?.contains("github") == true}
    var projects: [Project] = []; var workspaces: [Workspace] = []; var terminals: [TerminalRecord] = []
}

/// Separate the wire snapshot from observable UI state. A terminal update must
/// not invalidate readers of projects, workspaces, capabilities or the title bar.
@MainActor @Observable final class DaemonViewState {
    var protocolVersion = 1
    var hostName = "このMac"
    var revision = 0
    var features: [String]?
    var projects: [Project] = []
    var workspaces: [Workspace] = []
    var terminals: [TerminalRecord] = []
    // Tab ownership changes independently of activity, dimensions and process status.
    private(set) var terminalMembership: [TerminalMembership] = []
    var supportsMultipleTerminals: Bool {protocolVersion == 1 && features?.contains("terminal.multiple") == true}
    var supportsGitHub: Bool {protocolVersion == 1 && features?.contains("github") == true}

    func apply(_ snapshot: Snapshot) {
        if protocolVersion != snapshot.protocolVersion {protocolVersion = snapshot.protocolVersion}
        if hostName != snapshot.hostName {hostName = snapshot.hostName}
        if revision != snapshot.revision {revision = snapshot.revision}
        if features != snapshot.features {features = snapshot.features}
        if projects != snapshot.projects {projects = snapshot.projects}
        if workspaces != snapshot.workspaces {workspaces = snapshot.workspaces}
        let membership = snapshot.terminals.map {TerminalMembership(id: $0.id, workspaceId: $0.workspaceId, provider: $0.provider)}
        if terminalMembership != membership {terminalMembership = membership}
        if terminals != snapshot.terminals {terminals = snapshot.terminals}
    }
}
struct TerminalMembership: Equatable {
    let id: String
    let workspaceId: String
    let provider: String
}
struct FileEntry: Codable, Identifiable {var id: String {path}; let name: String; let path: String; let isDirectory: Bool}
struct DirectoryListing: Codable {let path: String; let entries: [FileEntry]}
struct FileContent: Codable, Equatable {let path: String; let content: String; let hash: String}
struct Change: Codable, Identifiable, Equatable {var id: String {path}; let path: String; let status: String}
struct GitStatus: Codable, Equatable {var branch: String = ""; var changes: [Change] = []}
struct Diff: Codable {let path: String; let content: String}
struct TerminalChunk: Codable {let data: String; let cols: Int?; let rows: Int?}
struct TerminalOutput: Codable {let data: String; let chunks: [TerminalChunk]; let cursor: Int; let more: Bool; let status: String; let cols: Int; let rows: Int}
struct APIError: Codable, Error, LocalizedError {let error: String; let message: String; var errorDescription: String? {message}}
struct CreatedWorkspace: Decodable {let id: String; let startupErrors: [String]?}
struct OK: Codable {let ok: Bool}

final class DaemonClient {
    let endpoint: URL
    let dataDirectory: URL
    let clientId: String
    private let session: URLSession
    @MainActor lazy var events = DaemonEvents.shared(endpoint: endpoint, dataDirectory: dataDirectory)
    init(endpoint: URL? = nil, dataDirectory: URL? = nil, session: URLSession? = nil) {
        clientId = UserDefaults.standard.string(forKey: "daemonClientId") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(clientId, forKey: "daemonClientId")
        self.endpoint = endpoint ?? URL(string: Bundle.main.object(forInfoDictionaryKey: "NeuraEndpoint") as? String ?? "http://127.0.0.1:4318")!
        self.dataDirectory = dataDirectory ?? URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") as? String ?? NSHomeDirectory() + "/Library/Application Support/neuraOS/Developer")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = session ?? URLSession(configuration: config)
    }
    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {try await request(path, query: query, timeout: (path.hasSuffix("/github") || path.hasSuffix("/pull-requests")) ? 180 : path.hasSuffix("/checks") ? 90 : 15)}
    func command<T: Decodable>(_ command: [String: Any]) async throws -> T {
        // One operation ID per user action. Never automatically resend uncertain terminal input.
        try await request("v1/commands", body: ["operationId": UUID().uuidString.lowercased(), "command": command], timeout: ((command["type"] as? String)?.hasPrefix("github.") == true || (command["type"] as? String)?.hasPrefix("workspace.") == true) ? 240 : 15)
    }
    private func request<T: Decodable>(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> T {
        let operationId = body?["operationId"] as? String
        let operation = (body?["command"] as? [String: Any])?["type"] as? String ?? "read.\(path.split(separator: "/").last.map(String.init) ?? "unknown")"
        let started = ProcessInfo.processInfo.systemUptime
        let traced = body != nil && !["terminal.input", "terminal.resize"].contains(operation)
        if traced {Diagnostics.shared.record("operation.start", operation: operation, id: operationId)}
        let slowTask: Task<Void, Never>? = traced ? Task {
            do {try await Task.sleep(for: .seconds(10))} catch {return}
            if traced {Diagnostics.shared.record("operation.slow", operation: operation, id: operationId, duration: ProcessInfo.processInfo.systemUptime - started)}
        } : nil
        defer {slowTask?.cancel()}
        var statusCode: Int?
        do {
            var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = query.isEmpty ? nil : query.sorted(by: {$0.key < $1.key}).map {URLQueryItem(name: $0.key, value: $0.value)}
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = timeout
            let token = try String(contentsOf: dataDirectory.appendingPathComponent("daemon-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body)}
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                statusCode = (response as? HTTPURLResponse)?.statusCode
                throw (try? JSONDecoder().decode(APIError.self, from: data)) ?? APIError(error: "connection", message: "Daemonへの接続に失敗しました。")
            }
            let value = try JSONDecoder().decode(T.self, from: data)
            if traced {Diagnostics.shared.record("operation.success", operation: operation, id: operationId, duration: ProcessInfo.processInfo.systemUptime - started)}
            return value
        } catch {
            Diagnostics.shared.record("operation.failure", operation: operation, id: operationId, duration: ProcessInfo.processInfo.systemUptime - started, code: statusCode ?? (error as NSError).code)
            throw error
        }
    }
}

@MainActor @Observable final class AppModel {
    let api = DaemonClient()
    let agentSleep = AgentSleepController()
    let githubUpdated = PassthroughSubject<String, Never>()
    let workspaceUpdated = PassthroughSubject<String, Never>()
    let state = DaemonViewState()
    var selectedId: String? = UserDefaults.standard.string(forKey: "selectedWorkspace")
    var connected = false
    var providerUsage: [ProviderUsage] = []
    var usageFailed = false
    var error: String?
    let terminalLaunchesChanged = PassthroughSubject<Void, Never>()
    let pendingActionsChanged = PassthroughSubject<Void, Never>()
    private(set) var startingTerminalTabs: Set<String> = [] {didSet {terminalLaunchesChanged.send()}}
    func isTerminalStarting(_ tabId: String) -> Bool {startingTerminalTabs.contains(tabId)}
    @discardableResult func beginTerminalLaunch(_ tabId: String) -> Bool {startingTerminalTabs.insert(tabId).inserted}
    func endTerminalLaunch(_ tabId: String) {startingTerminalTabs.remove(tabId)}
    private(set) var actionStarted: [String: Date] = [:]
    private(set) var pendingActions: [String: String] = [:] {didSet {pendingActionsChanged.send()}}
    func isBusy(_ key: String) -> Bool {pendingActions[key] != nil}
    @discardableResult func beginAction(_ key: String, label: String) -> Bool {
        guard !isBusy(key) else {Diagnostics.shared.record("action.blocked", operation: "resource.busy"); return false}
        actionStarted[key] = Date()
        pendingActions[key] = label
        return true
    }
    func endAction(_ key: String) {actionStarted.removeValue(forKey: key); pendingActions.removeValue(forKey: key)}
    var pendingWorkspaceDeletion: Workspace?
    var showNewProject = false
    var showNewWorkspace = false
    var showNewSpace = false
    var sidebarSpaces: SidebarSpaces = {
        if let data = UserDefaults.standard.data(forKey: "sidebarSpaces"),
           let saved = try? JSONDecoder().decode(SidebarSpaces.self, from: data), !saved.spaces.isEmpty {return saved}
        return SidebarSpaces()
    }() {
        didSet {if let data = try? JSONEncoder().encode(sidebarSpaces) {UserDefaults.standard.set(data, forKey: "sidebarSpaces")}}
    }
    var visibleProjects: [Project] {sidebarSpaces.projects(in: sidebarSpaces.active.id, from: state.projects)}
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
    var showSidebar = UserDefaults.standard.object(forKey: "showLeftSidebar") as? Bool ?? true {
        didSet {UserDefaults.standard.set(showSidebar, forKey: "showLeftSidebar")}
    }
    var showInspector = UserDefaults.standard.object(forKey: "showRightSidebar") as? Bool ?? true {
        didSet {UserDefaults.standard.set(showInspector, forKey: "showRightSidebar")}
    }
    let workspaceCommands = PassthroughSubject<WorkspaceCommandRequest, Never>()
    var openedIds: Set<String> = []
    var requestedTerminalId: String?
    private var agentNotifications: AgentNotifications?
    private var polling: Task<Void, Never>?
    private let statePulse = EventPulse()
    private var eventObserver: UUID?
    var gitProjects: [Project] {visibleProjects.filter { $0.supportsGit }}
    var selected: Workspace? {state.workspaces.first {$0.id == selectedId}}
    var supportsGitHub: Bool {connected && state.supportsGitHub}
    init(startPolling: Bool = true) {
        guard startPolling else {return}
        agentNotifications = AgentNotifications { [weak self] terminalId in
            guard let self, let terminal = self.terminal(id: terminalId) else {return}
            self.select(terminal.workspaceId)
            self.requestedTerminalId = terminalId
        }
        eventObserver = api.events.observe { [weak self] change in
            guard let self else {return}
            if change.type == "disconnected" {self.updateConnection(false)}
            if change.type == "ready" || change.state == true {self.statePulse.signal()}
        }
        polling = Task { [weak self] in
            guard let self else {return}
            var updates = self.statePulse.stream.makeAsyncIterator()
            while !Task.isCancelled {
                await self.refresh()
                if self.api.events.supported && self.connected {
                    guard await updates.next() != nil else {return}
                } else {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
    func refresh() async {
        do {
            let next: Snapshot = try await api.get("v1/state")
            guard next.protocolVersion == 1 else {throw APIError(error: "protocol", message: "Daemonとアプリのバージョンが一致しません。")}
            // A daemon upgrade can change features without changing stored data/revision.
            applySnapshot(next)
            api.events.configure(features: next.features)
            updateConnection(true)
            if (selectedId != nil || !visibleWorkspaces.isEmpty), !visibleWorkspaces.contains(where: {$0.id == selectedId}) {
                let saved = sidebarSpaces.active.selectedWorkspaceId
                select(visibleWorkspaces.first(where: {$0.id == saved})?.id ?? visibleWorkspaces.first?.id)
            }
            if sidebarSpaces.active.selectedWorkspaceId != selectedId {sidebarSpaces.remember(selectedId)}
            if let selectedId, !openedIds.contains(selectedId) {openedIds.insert(selectedId)}
            await agentNotifications?.receive(next, api: api)
        } catch {updateConnection(false)}
        agentSleep.update(terminals: state.terminals, connected: connected)
    }
    // Transport polling must not invalidate views when the UI state is unchanged.
    func applySnapshot(_ next: Snapshot) {
        state.apply(next)
        let retained = openedIds.intersection(Set(next.workspaces.map(\.id)))
        if retained != openedIds {openedIds = retained}
    }
    func updateConnection(_ value: Bool) {
        // Older Observation runtimes notify even for an equal assignment.
        guard connected != value else {return}
        Diagnostics.shared.record(value ? "daemon.connected" : "daemon.disconnected")
        connected = value
    }
    func select(_ id: String?) {
        Diagnostics.shared.record("action.select-workspace")
        if let workspace = state.workspaces.first(where: {$0.id == id}) {sidebarSpaces.activeId = sidebarSpaces.owner(of: workspace.projectId)}
        sidebarSpaces.remember(id)
        selectedId = id; if let id {openedIds.insert(id)}; UserDefaults.standard.set(id, forKey: "selectedWorkspace")}
    func report(_ error: Error) {self.error = error.localizedDescription}
    func refreshUsage() async {
        do {
            let response: ProviderUsageResponse = try await api.get("v1/usage")
            if providerUsage != response.providers {providerUsage = response.providers}
            if usageFailed {usageFailed = false}
        } catch {if !usageFailed {usageFailed = true}; if !providerUsage.isEmpty {providerUsage = []}}
    }
    var supportsFolderless: Bool {state.features?.contains("project.folderless") == true}
    func createProject(name: String) async {
        let targetSpaceId = sidebarSpaces.active.id
        guard beginAction("project.create", label: "プロジェクトを作成中") else {return}
        defer {endAction("project.create")}
        do {
            let project: Project = try await api.command(["type": "project.create", "name": name])
            sidebarSpaces.projectSpaces[project.id] = targetSpaceId
            await refresh(); select(state.workspaces.first {$0.projectId == project.id}?.id)
            showNewProject = false
        } catch {report(error)}
    }
    func attachFolder(to project: Project) {
        guard supportsFolderless, project.folderless == true, !isBusy("project.attach.\(project.id)") else {return}
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "フォルダ用の作業領域を追加します。現在のタブと会話は「フリー」に残ります。"
        panel.prompt = "紐づける"
        guard panel.runModal() == .OK, let path = panel.url?.path else {return}
        let key = "project.attach.\(project.id)"
        guard beginAction(key, label: "フォルダを紐づけ中") else {return}
        Task {defer {endAction(key)}; do {
            let _: Project = try await api.command(["type": "project.attach", "projectId": project.id, "path": path])
            await refresh()
            select(state.workspaces.first {$0.projectId == project.id && $0.hasFolder}?.id)
        } catch {report(error)}}
    }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "作業するフォルダを選択（Gitは不要です）"; panel.prompt = "追加"
        guard panel.runModal() == .OK, let path = panel.url?.path else {return}
        let targetSpaceId = sidebarSpaces.active.id
        guard beginAction("project.add", label: "フォルダを追加中") else {return}
        Task {defer {endAction("project.add")}; do {
            let project: Project = try await api.command(["type": "project.add", "path": path])
            sidebarSpaces.projectSpaces[project.id] = targetSpaceId
            await refresh(); select(state.workspaces.first {$0.projectId == project.id}?.id)
        } catch {report(error)}}
    }
    func conversationProvider(for workspace: Workspace) -> String {
        state.projects.first {$0.id == workspace.projectId}?.conversationProvider ?? "codex"
    }
    func setDefaultProvider(_ project: Project, provider: String, delegation: Bool) async {
        let key = "project.settings.\(project.id)"
        guard state.features?.contains("project.default-providers") == true,
              ["codex", "claude"].contains(provider), beginAction(key, label: "既定のAIを保存中") else {return}
        defer {endAction(key)}
        do {
            let field = delegation ? "defaultDelegationProvider" : "defaultConversationProvider"
            let _: Project = try await api.command(["type": "project.set-default-providers", "projectId": project.id, field: provider])
            await refresh()
        } catch {report(error)}
    }
    func setWorktreeStartup(_ project: Project, provider: String, enabled: Bool) async {
        let key = "project.settings.\(project.id)"
        guard beginAction(key, label: "自動起動設定を保存中") else {return}
        defer {endAction(key)}
        do {
            var providers = state.projects.first(where: {$0.id == project.id})?.worktreeStartup ?? []
            providers.removeAll {$0 == provider}
            if enabled {providers.append(provider)}
            let _: Project = try await api.command(["type": "project.set-worktree-startup", "projectId": project.id, "providers": providers])
            await refresh()
        } catch {report(error)}
    }
    func createWorkspace(projectId: String, base: String?, pullRequest: String? = nil) async {
        let key = "project.create.\(projectId)"
        guard beginAction(key, label: "作業を作成中") else {return}
        defer {endAction(key)}
        do {
            guard state.features?.contains("workspace.remote-default") == true else {throw APIError(error: "daemon_update_required", message: "Daemonを更新してから作成してください。")}
            var command: [String: Any] = ["type": "workspace.create", "projectId": projectId]
            if let base {command["baseRef"] = base}
            if let pullRequest {
                guard state.features?.contains("workspace.from-pr") == true else {throw APIError(error: "daemon_update_required", message: "Daemonを更新してからPRを指定してください。")}
                command["pullRequest"] = pullRequest
            }
            let workspace: CreatedWorkspace = try await api.command(command)
            await refresh(); select(workspace.id); showNewWorkspace = false
            if let failures = workspace.startupErrors, !failures.isEmpty {
                error = "worktreeは作成されましたが、自動起動に失敗しました。\n" + failures.joined(separator: "\n")
            }
        } catch {report(error)}
    }
    func syncDefault(_ workspace: Workspace) async {
        guard beginAction(workspace.id, label: "リモートから更新中") else {return}
        defer {endAction(workspace.id)}
        do {
            let _: Workspace = try await api.command(["type": "workspace.sync-default", "workspaceId": workspace.id])
            workspaceUpdated.send(workspace.id)
            await refresh()
        } catch {report(error)}
    }
    func removeProject(_ project: Project) async {
        let key = "project.remove.\(project.id)"
        guard beginAction(key, label: "プロジェクトを削除中") else {return}
        defer {endAction(key)}
        do {
            guard state.features?.contains("project.remove") == true else {
                throw APIError(error: "daemon_update_required", message: "Daemonを更新してから削除してください。")
            }
            let _: OK = try await api.command(["type": "project.remove", "projectId": project.id])
            await refresh()
        } catch {report(error)}
    }
    func deleteWorkspace(_ workspace: Workspace, discardChanges: Bool = false) async {
        guard workspace.kind == "worktree", beginAction(workspace.id, label: "作業を削除中") else {return}
        defer {endAction(workspace.id)}
        do {
            guard state.features?.contains("workspace.delete.stop-terminals") == true else {
                throw APIError(error: "daemon_update_required", message: "Daemonを更新してから削除してください。")
            }
            let _: OK = try await api.command(["type": "workspace.delete", "workspaceId": workspace.id, "discardChanges": discardChanges, "stopTerminals": true])
            await refresh()
        } catch let failure as APIError where !discardChanges && ["workspace_dirty", "workspace_ignored_files"].contains(failure.error) {
            pendingWorkspaceDeletion = workspace
        } catch {report(error)}
    }
    func openTerminal(_ workspace: Workspace, provider: String? = nil, resume: Bool = false) async -> TerminalRecord? {
        guard beginAction(workspace.id, label: "ターミナルを起動中") else {return nil}
        defer {endAction(workspace.id)}
        do {
            // Check before sending: concurrent opens against legacy daemons can return the same PTY.
            guard state.supportsMultipleTerminals else {
                throw APIError(error: "daemon_update_required", message: "Daemonの更新が必要です。実行中の作業を終えてから pnpm service restart を実行してください。")
            }
            let terminal: TerminalRecord = try await api.command(["type": "terminal.open", "workspaceId": workspace.id, "provider": provider ?? conversationProvider(for: workspace), "resume": resume])
            await refresh(); return terminal
        } catch {report(error); return nil}
    }
    @discardableResult func stopTerminal(_ terminal: TerminalRecord) async -> Bool {
        do {let _: OK = try await api.command(["type": "terminal.stop", "terminalId": terminal.id]); await refresh(); return true} catch {report(error); return false}
    }
    func terminal(id: String?) -> TerminalRecord? {state.terminals.first {$0.id == id}}
}


struct ProviderUsageResponse: Decodable {let providers: [ProviderUsage]}
struct UsageWindow: Decodable, Equatable {
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
struct ProviderUsage: Decodable, Identifiable, Equatable {
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
