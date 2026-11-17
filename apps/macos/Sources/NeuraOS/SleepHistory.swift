import Foundation

/// A closed vocabulary deliberately excludes provider errors, prompts, names,
/// SSIDs, IP addresses, tokens and conversation content.
struct SleepHistoryEvent: Codable, Identifiable, Equatable {
    enum Source: String, Codable {case os, observation, inference}
    enum Kind: String, Codable {
        case gap, sleep, wake, lidClosed, lidOpened, lidUnavailable
        case suppressionStarted, suppressionStopped, suppressionUnknown, suppressionGrace, controlFailed
        case wifiUp, wifiDown, internetUp, internetDown, daemonUp, daemonDown
        case providerUp, providerDown, providerError, providerRetry, agentFailed, agentInterrupted, agentRetry, agentRecovered
        case agentCompleted, agentWaiting, agentUnknown
        var label: String {
            switch self {
            case .gap: return "観測の欠落"
            case .sleep: return "OS スリープ通知"
            case .wake: return "OS 復帰通知"
            case .lidClosed: return "蓋を閉じた状態を取得"
            case .lidOpened: return "蓋を開いた状態を取得"
            case .lidUnavailable: return "蓋の状態を取得できません"
            case .suppressionStarted: return "スリープ抑制を確認"
            case .suppressionStopped: return "スリープ抑制の解除を確認"
            case .suppressionGrace: return "抑制解除の猶予"
            case .controlFailed: return "スリープ制御の失敗"
            case .suppressionUnknown: return "スリープ抑制の確認が途絶えました"
            case .wifiUp: return "Wi-Fi 経路が利用可能"
            case .wifiDown: return "Wi-Fi 経路が利用不可"
            case .internetUp: return "インターネット到達を確認"
            case .internetDown: return "インターネット到達を確認できません"
            case .daemonUp: return "daemon 接続を確認"
            case .daemonDown: return "daemon 接続断"
            case .providerUp: return "provider 接続を確認"
            case .providerDown: return "provider 接続を確認できません"
            case .providerError: return "provider が実行エラーを報告"
            case .providerRetry: return "provider が再試行を予定"
            case .agentFailed: return "エージェント実行失敗"
            case .agentInterrupted: return "エージェント実行中断"
            case .agentRetry: return "中断・失敗後に新しい実行を観測"
            case .agentRecovered: return "エージェント正常完了へ復旧"
            case .agentCompleted: return "正常完了"
            case .agentWaiting: return "回答・承認待ち"
            case .agentUnknown: return "エージェント状態不明"
            }
        }
    }
    enum Reason: String, Codable {
        case initial, changed, appNotObserving, systemSleep, samplingGap, work, completionGrace, connectionGrace
        case normalSleep, externalSuppression, stale, unavailable, endpointProbe, channelReport, turnReport, providerRetry, providerError, agentUnavailable, causeUnknown
        var label: String {
            switch self {
            case .initial: return "観測開始時点の状態（開始日時は不明）"
            case .changed: return "前回観測からの変化"
            case .appNotObserving: return "アプリ停止中・未観測。期間内の出来事は不明"
            case .systemSleep: return "スリープ中は観測できません"
            case .samplingGap: return "監視が遅延した期間。原因は不明"
            case .work: return "helper が作業中の抑制を確認"
            case .completionGrace: return "完了・回答待ち後の解除猶予（5秒）"
            case .connectionGrace: return "作業状態不明の解除猶予（最大30秒）"
            case .normalSleep: return "OS の SleepDisabled が無効。通常のスリープ動作"
            case .externalSuppression: return "OS の抑制は有効ですが、このアプリの確認はありません"
            case .stale: return "helper の確認が古い、または取得できません"
            case .unavailable: return "この環境では取得できません"
            case .endpointProbe: return "固定 HTTPS 確認先への到達性。インターネット全体を保証しません"
            case .channelReport: return "daemon の provider 接続報告。原因は不明"
            case .turnReport: return "daemon の実行状態報告。原因は不明"
            case .providerRetry: return "provider が再試行予定を報告。原因は不明"
            case .providerError: return "provider の error 通知。原因は不明"
            case .agentUnavailable: return "エージェント一覧の取得不能期間。期間内の状態変化と原因は不明"
            case .causeUnknown: return "原因は不明。同時期の出来事との因果関係は未確認"
            }
        }
    }
    var id = UUID()
    var date: Date
    var kind: Kind
    var source: Source
    var reason: Reason
    var since: Date? = nil
    var projectID: String? = nil
    var workspaceID: String? = nil
    var terminalID: String? = nil
    var sessionID: String? = nil
    var turnID: String? = nil
    var duration: TimeInterval? {since.map {max(0, date.timeIntervalSince($0))}}
}

/// Single app-owned file, atomically replaced; bounded on disk and on load.
/// Session references are opaque IDs, never user-generated titles or text.
@MainActor final class SleepHistoryStore: ObservableObject {
    static let retention: TimeInterval = 14 * 24 * 3600
    static let maxEvents = 2000
    static let maxBytes = 1_048_576
    struct Archive: Codable {var version = 1; var observedThrough: Date; var events: [SleepHistoryEvent]}
    @Published private(set) var events: [SleepHistoryEvent] = []
    @Published private(set) var storageFailed = false
    private let file: URL
    private var observedThrough: Date
    private var loadFailed = false
    private var lastSave: Date
    init(file: URL, now: Date = Date()) {
        self.file = file; observedThrough = now; lastSave = now
        var previous: Date?
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maxBytes else {throw CocoaError(.fileReadTooLarge)}
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1 else {throw CocoaError(.fileReadCorruptFile)}
                events = archive.events; previous = archive.observedThrough
            } catch {storageFailed = true; loadFailed = true}
        }
        prune(now: now)
        append(.init(date: now, kind: .gap, source: .observation, reason: .appNotObserving, since: previous), now: now)
    }
    func append(_ event: SleepHistoryEvent, now: Date = Date()) {
        // Refuse arbitrary strings even if a future caller passes unsafe IDs.
        var safe = event
        func identifier(_ value: String?) -> String? {
            guard let value, value.count <= 128, !value.isEmpty,
                  value.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0))}) else {return nil}
            return value
        }
        safe.projectID = identifier(event.projectID); safe.workspaceID = identifier(event.workspaceID)
        safe.terminalID = identifier(event.terminalID); safe.sessionID = identifier(event.sessionID); safe.turnID = identifier(event.turnID)
        guard !events.contains(where: {$0.id == safe.id}) else {return}
        events.append(safe); events.sort {$0.date < $1.date}
        observedThrough = now; save(now: now)
    }
    func checkpoint(now: Date = Date()) {
        observedThrough = now
        if now.timeIntervalSince(lastSave) >= 30 {save(now: now)}
    }
    func flush(now: Date = Date()) {observedThrough = now; save(now: now)}
    private func prune(now: Date) {
        events = Array(events.filter {$0.date >= now.addingTimeInterval(-Self.retention)}.suffix(Self.maxEvents))
    }
    private func save(now: Date) {
        prune(now: now)
        do {
            let encoder = JSONEncoder()
            var data = try encoder.encode(Archive(observedThrough: observedThrough, events: events))
            while data.count > Self.maxBytes && !events.isEmpty {
                events.removeFirst(min(100, events.count))
                data = try encoder.encode(Archive(observedThrough: observedThrough, events: events))
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lastSave = now; storageFailed = loadFailed
        } catch {storageFailed = true}
    }
}

/// Decodes only metadata from the existing daemon's bounded summary listing.
struct SleepAgentPage: Decodable {
    let agents: [SleepAgentState]
    let nextCursor: String?
    let fullRefreshRequired: Bool?
}
struct SleepAgentState: Decodable, Equatable {
    let id: String
    let terminalId: String
    let workspaceId: String
    let status: String
    let channelState: String?
    var providerConnection: String? = nil
    let turnId: String?
    let lastTurnId: String?
    let lastTurnStatus: String?
    var runtimeIssue: RuntimeIssue? = nil
    struct RuntimeIssue: Decodable, Equatable {
        let id: UUID
        let at: String
        let willRetry: Bool
        let turnId: String?
    }
}

struct SleepAgentTracker {
    private var previous: [String: SleepAgentState] = [:]
    // A session can contain unrelated turns. Only an issue observed on the
    // active turn can establish recovery when that same turn completes.
    private var troubledTurn: [String: String] = [:]
    private var statusSince: [String: Date] = [:]
    private var connectionSince: [String: Date] = [:]
    mutating func observe(_ agents: [SleepAgentState], projects: [String: String], now: Date) -> [SleepHistoryEvent] {
        var events: [SleepHistoryEvent] = []
        for agent in agents {
            let old = previous[agent.id]
            let previouslyTroubledTurn = troubledTurn[agent.id]
            func event(_ kind: SleepHistoryEvent.Kind, _ reason: SleepHistoryEvent.Reason = .turnReport, source: SleepHistoryEvent.Source = .observation, since: Date? = nil, turn: String? = nil) {
                events.append(.init(date: now, kind: kind, source: source, reason: old == nil ? .initial : reason, since: since,
                                    projectID: projects[agent.workspaceId], workspaceID: agent.workspaceId,
                                    terminalID: agent.terminalId, sessionID: agent.id, turnID: turn ?? agent.turnId ?? agent.lastTurnId))
            }
            if let issue = agent.runtimeIssue, issue.id != old?.runtimeIssue?.id {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let at = formatter.date(from: issue.at) ?? ISO8601DateFormatter().date(from: issue.at) ?? now
                events.append(.init(id: issue.id, date: at, kind: issue.willRetry ? .providerRetry : .providerError,
                                    source: .observation, reason: issue.willRetry ? .providerRetry : .providerError,
                                    projectID: projects[agent.workspaceId], workspaceID: agent.workspaceId,
                                    terminalID: agent.terminalId, sessionID: agent.id, turnID: issue.turnId))
                if let turn = issue.turnId, turn == agent.turnId,
                   ["working", "waiting"].contains(agent.status) {
                    troubledTurn[agent.id] = turn
                }
            }
            if let channel = agent.providerConnection ?? agent.channelState, channel != (old?.providerConnection ?? old?.channelState) {
                if channel == "connected" {event(.providerUp, .channelReport, since: connectionSince[agent.id])}
                else if ["unavailable", "disconnected"].contains(channel) {event(.providerDown, .channelReport, since: connectionSince[agent.id])}
                connectionSince[agent.id] = now
            }
            let lifecycleChanged = old?.status != agent.status || old?.turnId != agent.turnId
                || old?.lastTurnId != agent.lastTurnId || old?.lastTurnStatus != agent.lastTurnStatus
            if lifecycleChanged {
                // A terminal may close (or a new turn start) between polls. Report
                // the observed turn's explicit outcome before session-level inference.
                let observedOutcome = old?.turnId != nil && old?.turnId == agent.lastTurnId
                    && old?.turnId != agent.turnId
                    ? agent.lastTurnStatus : nil
                func completed(_ turn: String?) {
                    let recovered = turn != nil && (troubledTurn[agent.id] == turn || previouslyTroubledTurn == turn)
                    event(recovered ? .agentRecovered : .agentCompleted,
                          since: statusSince[agent.id], turn: turn)
                    if troubledTurn[agent.id] == turn {troubledTurn.removeValue(forKey: agent.id)}
                }
                var reportedOutcome = true
                switch observedOutcome {
                case "completed": completed(agent.lastTurnId)
                case "failed": event(.agentFailed, since: statusSince[agent.id], turn: agent.lastTurnId)
                case "interrupted": event(.agentInterrupted, since: statusSince[agent.id], turn: agent.lastTurnId)
                default: reportedOutcome = false
                }
                if !reportedOutcome || ["working", "waiting"].contains(agent.status) {
                    switch agent.status {
                    case "failed": event(.agentFailed, since: statusSince[agent.id], turn: old?.turnId)
                    case "interrupted":
                        // Restoration/closure alone does not establish a failed turn.
                        if old == nil && agent.lastTurnStatus == "failed" {
                            event(.agentFailed)
                        } else if agent.lastTurnStatus == "interrupted"
                                    && (old == nil || old?.lastTurnId != agent.lastTurnId
                                        || old?.lastTurnStatus != agent.lastTurnStatus) {
                            event(.agentInterrupted, since: statusSince[agent.id], turn: agent.lastTurnId)
                        } else if old?.status == "working" || old?.status == "waiting" {
                            event(.agentInterrupted, .causeUnknown, source: .inference,
                                  since: statusSince[agent.id], turn: old?.turnId)
                        } else {event(.agentUnknown, .causeUnknown)}
                    case "waiting": event(.agentWaiting, since: statusSince[agent.id])
                    case "idle":
                        if agent.lastTurnStatus == "completed",
                           old == nil || old?.turnId != nil || old?.lastTurnId != agent.lastTurnId
                            || old?.lastTurnStatus != agent.lastTurnStatus {
                            // Do not reuse a stale completion for a different active turn.
                            if old?.turnId == nil || old?.turnId == agent.lastTurnId {
                                completed(agent.lastTurnId)
                            } else {event(.agentUnknown, .causeUnknown, turn: old?.turnId)}
                        }
                    case "working": break // A new turn is not evidence of a retry.
                    default: event(.agentUnknown, .causeUnknown)
                    }
                }
            }
            if troubledTurn[agent.id] != agent.turnId {
                troubledTurn.removeValue(forKey: agent.id)
            }
            if old?.status != agent.status || old?.turnId != agent.turnId {statusSince[agent.id] = now}
            previous[agent.id] = agent
        }
        // Disappearance is not completion. Keep no unbounded session cache.
        let ids = Set(agents.map(\.id))
        previous = previous.filter {ids.contains($0.key)}
        troubledTurn = troubledTurn.filter {ids.contains($0.key)}
        statusSince = statusSince.filter {ids.contains($0.key)}; connectionSince = connectionSince.filter {ids.contains($0.key)}
        return events
    }
}
