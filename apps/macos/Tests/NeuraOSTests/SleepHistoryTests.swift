import XCTest
@testable import NeuraOS

final class SleepHistoryTests: XCTestCase {
    func testFooterRequiresFreshHelperAndOSConfirmation() {
        func state(_ helper: String? = nil, os: Bool? = true, fresh: Bool = true, enabled: Bool = true, permission: Bool = false, failed: Bool = false, starting: Bool = false, stopping: Bool = false, lid: Bool = true) -> SleepFooterState.Kind {
            SleepFooterState.derive(starting: starting, stopping: stopping, permission: permission, failed: failed,
                                    enabled: enabled, freshWork: fresh, helper: helper, sleepDisabled: os, lidAvailable: lid).kind
        }
        let work = "作業中：蓋を閉じても継続します"
        XCTAssertEqual(state(work), .continues)
        XCTAssertEqual(state(work, os: false), .sleeps)
        XCTAssertEqual(state(work, os: nil), .unknown)
        XCTAssertEqual(state(work, fresh: false), .unknown)
        XCTAssertEqual(state(work, enabled: false), .unknown)
        XCTAssertEqual(state(work, lid: false), .unknown)
        XCTAssertEqual(state(), .unknown)
        XCTAssertEqual(state("作業終了を確認中…"), .releaseGrace)
        XCTAssertEqual(state("作業状態を確認できません（30秒で抑制解除）"), .connectionGrace)
        XCTAssertEqual(state(permission: true), .permission)
        XCTAssertEqual(state(failed: true), .failed)
        XCTAssertEqual(state(starting: true), .checking)
        XCTAssertEqual(state(stopping: true), .checking)
        XCTAssertEqual(state(os: false, enabled: false), .sleeps)
    }
    @MainActor func testHistoryPersistsWithGapAndPrunesAndRejectsSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: directory)}
        let file = directory.appendingPathComponent("events.json"), now = Date()
        let store = SleepHistoryStore(file: file, now: now)
        store.append(.init(date: now.addingTimeInterval(-SleepHistoryStore.retention - 1), kind: .wifiDown, source: .observation, reason: .changed), now: now)
        store.append(.init(date: now, kind: .agentFailed, source: .observation, reason: .causeUnknown,
                           projectID: "project-id", sessionID: "secret token with spaces"), now: now)
        XCTAssertFalse(store.events.contains {$0.kind == .wifiDown})
        XCTAssertNil(store.events.last?.sessionID)
        XCTAssertEqual(store.events.last?.projectID, "project-id")
        let restarted = SleepHistoryStore(file: file, now: now.addingTimeInterval(60))
        XCTAssertEqual(restarted.events.last?.kind, .gap)
        XCTAssertEqual(restarted.events.last?.duration, 60)
        XCTAssertTrue(restarted.events.contains {$0.kind == .agentFailed})
        XCTAssertFalse(restarted.storageFailed)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    @MainActor func testStorageBoundsLoadAndSaveAndReportsWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {try? FileManager.default.removeItem(at: directory)}
        let file = directory.appendingPathComponent("events.json"), now = Date()
        let events = (0..<2500).map {_ in SleepHistoryEvent(date: now, kind: .wake, source: .os, reason: .changed)}
        try JSONEncoder().encode(SleepHistoryStore.Archive(observedThrough: now, events: events)).write(to: file)
        let store = SleepHistoryStore(file: file, now: now)
        XCTAssertLessThanOrEqual(store.events.count, SleepHistoryStore.maxEvents)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, SleepHistoryStore.maxBytes)
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failed = SleepHistoryStore(file: blocked.appendingPathComponent("events.json"))
        XCTAssertTrue(failed.storageFailed)
    }
    @MainActor func testOversizedAndCorruptArchivesAreVisibleAsMissingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {try? FileManager.default.removeItem(at: directory)}
        let file = directory.appendingPathComponent("events.json")
        for data in [Data(repeating: 32, count: SleepHistoryStore.maxBytes + 1), Data("broken".utf8)] {
            try data.write(to: file)
            let store = SleepHistoryStore(file: file)
            XCTAssertTrue(store.storageFailed)
            XCTAssertEqual(store.events.map(\.kind), [.gap])
            XCTAssertNil(store.events.first?.since)
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, SleepHistoryStore.maxBytes)
        }
    }
    @MainActor func testProviderRetryCanBeObservedAfterCompletionWithoutPersistingErrorText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: directory)}
        let issueID = UUID()
        let at = Date()
        let json: [String: Any] = ["id":"session", "terminalId":"terminal", "workspaceId":"workspace", "status":"idle",
            "lastTurnId":"turn1", "lastTurnStatus":"completed", "runtimeIssue": ["id":issueID.uuidString,
                "at":ISO8601DateFormatter().string(from: at), "willRetry":true, "turnId":"turn1", "error":"SECRET text"]]
        let agent = try JSONDecoder().decode(SleepAgentState.self, from: JSONSerialization.data(withJSONObject: json))
        var tracker = SleepAgentTracker()
        let events = tracker.observe([agent], projects: [:], now: at)
        XCTAssertEqual(events.map(\.kind), [.providerRetry, .agentCompleted])
        XCTAssertEqual(events.first?.source, .observation)
        XCTAssertEqual(events.first?.reason, .providerRetry)
        let file = directory.appendingPathComponent("events.json")
        let store = SleepHistoryStore(file: file, now: at)
        for event in events {store.append(event)}
        let restarted = SleepHistoryStore(file: file)
        restarted.append(events[0])
        XCTAssertEqual(restarted.events.filter {$0.id == issueID}.count, 1)
        XCTAssertFalse(try String(contentsOf: file).contains("SECRET"))
        XCTAssertTrue(tracker.observe([agent], projects: [:], now: at).isEmpty)
    }
    private func snapshot(_ status: String, turn: String? = nil, lastTurn: String? = nil,
                          outcome: String? = nil) -> SleepAgentState {
        SleepAgentState(id: "session", terminalId: "terminal", workspaceId: "workspace",
                        status: status, channelState: nil, turnId: turn,
                        lastTurnId: lastTurn, lastTurnStatus: outcome)
    }

    func testAgentTransitionTable() {
        typealias Kind = SleepHistoryEvent.Kind
        typealias Step = (SleepAgentState, [Kind])
        let issueID = UUID()
        func state(_ status: String, _ turn: String? = nil, _ last: String? = nil, _ outcome: String? = nil,
                   issue: String? = nil, retry: Bool = false, connection: String? = nil) -> SleepAgentState {
            var value = snapshot(status, turn: turn, lastTurn: last, outcome: outcome)
            if let issue {
                value.runtimeIssue = .init(id: issueID, at: "2026-11-17T00:00:00Z",
                                           willRetry: retry, turnId: issue == "unscoped" ? nil : issue)
            }
            value.providerConnection = connection
            return value
        }
        let cases: [(String, [Step])] = [
            ("restart clean active", [(state("working", "t2", "t1"), []),
                                      (state("idle", nil, "t2", "completed"), [.agentCompleted])]),
            ("restart stale completed issue", [
                (state("working", "t2", "t1", "completed", issue: "t1"), [.providerError]),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("restart daemon clears outcome but retains last ID", [
                (state("working", "t2", "t1", issue: "t1", retry: true), [.providerRetry]),
                (state("idle", nil, "t2", "completed", issue: "t1", retry: true), [.agentCompleted])]),
            ("restart active issue", [
                (state("working", "t1", issue: "t1"), [.providerError]),
                (state("idle", nil, "t1", "completed", issue: "t1"), [.agentRecovered])]),
            ("restart waiting active retry", [
                (state("waiting", "t1", issue: "t1", retry: true), [.providerRetry, .agentWaiting]),
                (state("idle", nil, "t1", "completed", issue: "t1", retry: true), [.agentRecovered])]),
            ("restart completed historical retry", [
                (state("idle", nil, "t1", "completed", issue: "t1", retry: true), [.providerRetry, .agentCompleted]),
                (state("working", "t2", "t1", issue: "t1", retry: true), [])]),
            ("restart interrupted historical completion", [
                (state("interrupted", nil, "t1", "completed", issue: "t1"), [.providerError, .agentUnknown]),
                (state("working", "t2", "t1", issue: "t1"), []),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("restart failed", [(state("failed", nil, "t1", "failed"), [.agentFailed]),
                                (state("working", "t2", "t1"), []),
                                (state("idle", nil, "t2", "completed"), [.agentCompleted])]),
            ("restart interrupted fact", [(state("interrupted", nil, "t1", "interrupted"), [.agentInterrupted]),
                                          (state("working", "t2", "t1"), [])]),
            ("restart interrupted unknown", [(state("interrupted"), [.agentUnknown])]),
            ("same turn waiting is not failure", [
                (state("working", "t1"), []), (state("waiting", "t1"), [.agentWaiting]),
                (state("working", "t1"), []), (state("idle", nil, "t1", "completed"), [.agentCompleted])]),
            ("same turn active issue then closure", [
                (state("working", "t1"), []), (state("working", "t1", issue: "t1"), [.providerError]),
                (state("interrupted", nil, "t1", "completed", issue: "t1"), [.agentRecovered])]),
            ("same turn retry announcement", [
                (state("working", "t1"), []), (state("working", "t1", issue: "t1", retry: true), [.providerRetry]),
                (state("waiting", "t1", issue: "t1", retry: true), [.agentWaiting]),
                (state("idle", nil, "t1", "completed", issue: "t1", retry: true), [.agentRecovered])]),
            ("unscoped issue cannot establish recovery", [
                (state("working", "t1", issue: "unscoped"), [.providerError]),
                (state("idle", nil, "t1", "completed", issue: "unscoped"), [.agentCompleted])]),
            ("late issue after completion", [
                (state("working", "t1"), []),
                (state("idle", nil, "t1", "completed", issue: "t1"), [.providerError, .agentCompleted])]),
            ("new turn clears previous active issue", [
                (state("working", "t1", issue: "t1"), [.providerError]),
                (state("working", "t2", "t1", issue: "t1"), []),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("new waiting turn clears previous issue", [
                (state("working", "t1", issue: "t1"), [.providerError]),
                (state("waiting", "t2", "t1", issue: "t1"), [.agentWaiting]),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("failure then unrelated completion", [
                (state("working", "t1"), []), (state("failed", nil, "t1", "failed"), [.agentFailed]),
                (state("working", "t2", "t1"), []),
                (state("idle", nil, "t2", "completed"), [.agentCompleted])]),
            ("interruption then unrelated completion", [
                (state("working", "t1"), []), (state("interrupted", nil, "t1", "interrupted"), [.agentInterrupted]),
                (state("working", "t2", "t1"), []),
                (state("idle", nil, "t2", "completed"), [.agentCompleted])]),
            ("completion outranks failed session", [
                (state("working", "t1"), []), (state("failed", nil, "t1", "completed"), [.agentCompleted])]),
            ("failed outcome before terminal closure", [
                (state("working", "t1"), []), (state("interrupted", nil, "t1", "failed"), [.agentFailed])]),
            ("working completion before closure", [
                (state("working", "t1"), []), (state("interrupted", nil, "t1", "completed"), [.agentCompleted])]),
            ("waiting completion before closure", [
                (state("waiting", "t1"), [.agentWaiting]),
                (state("interrupted", nil, "t1", "completed"), [.agentCompleted])]),
            ("waiting interruption without outcome", [
                (state("waiting", "t1"), [.agentWaiting]), (state("interrupted"), [.agentInterrupted])]),
            ("stale completion cannot hide active interruption", [
                (state("working", "t2", "t1"), []),
                (state("interrupted", nil, "t1", "completed"), [.agentInterrupted])]),
            ("new active issue and previous completion in one poll", [
                (state("working", "t1"), []),
                (state("working", "t2", "t1", "completed", issue: "t2"), [.providerError, .agentCompleted]),
                (state("idle", nil, "t2", "completed", issue: "t2"), [.agentRecovered])]),
            ("previous recovery and new waiting turn in one poll", [
                (state("working", "t1", issue: "t1"), [.providerError]),
                (state("waiting", "t2", "t1", "completed", issue: "t1"), [.agentRecovered, .agentWaiting]),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("same status outcome arrives later", [
                (state("interrupted"), [.agentUnknown]),
                (state("interrupted", nil, "t1", "interrupted"), [.agentInterrupted])]),
            ("stale idle completion cannot recover active turn", [
                (state("working", "t2", "t1", issue: "t2"), [.providerError]),
                (state("idle", nil, "t1", "completed", issue: "t2"), [.agentUnknown])]),
            ("completed status churn cannot duplicate outcome", [
                (state("idle", nil, "t1", "completed"), [.agentCompleted]),
                (state("interrupted", nil, "t1", "completed"), [.agentUnknown]),
                (state("idle", nil, "t1", "completed"), [])]),
            ("interrupted status churn cannot duplicate incident", [
                (state("interrupted", nil, "t1", "interrupted"), [.agentInterrupted]),
                (state("idle", nil, "t1", "interrupted"), []),
                (state("interrupted", nil, "t1", "interrupted"), [.agentUnknown])]),
            ("restart closed failed turn", [
                (state("interrupted", nil, "t1", "failed"), [.agentFailed]),
                (state("working", "t2", "t1"), []),
                (state("idle", nil, "t2", "completed"), [.agentCompleted])]),
            ("restart historical failed issue", [
                (state("failed", nil, "t1", "failed", issue: "t1"), [.providerError, .agentFailed]),
                (state("waiting", "t2", "t1", issue: "t1"), [.agentWaiting]),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("active error followed by failed outcome and clean turn", [
                (state("working", "t1", issue: "t1"), [.providerError]),
                (state("failed", nil, "t1", "failed", issue: "t1"), [.agentFailed]),
                (state("working", "t2", "t1", issue: "t1"), []),
                (state("idle", nil, "t2", "completed", issue: "t1"), [.agentCompleted])]),
            ("connection recovery does not resolve active issue", [
                (state("working", "t1", issue: "t1", connection: "unavailable"), [.providerError, .providerDown]),
                (state("working", "t1", issue: "t1", connection: "connected"), [.providerUp]),
                (state("idle", nil, "t1", "completed", issue: "t1", connection: "connected"), [.agentRecovered])]),
            ("connection changes do not imply incidents", [
                (state("working", "t1", connection: "connected"), [.providerUp]),
                (state("working", "t1", connection: "disconnected"), [.providerDown]),
                (state("working", "t1", connection: "connected"), [.providerUp]),
                (state("idle", nil, "t1", "completed", connection: "connected"), [.agentCompleted])]),
            ("connection changes with stale issue", [
                (state("working", "t2", "t1", issue: "t1", connection: "disconnected"), [.providerError, .providerDown]),
                (state("working", "t2", "t1", issue: "t1", connection: "connected"), [.providerUp]),
                (state("idle", nil, "t2", "completed", issue: "t1", connection: "connected"), [.agentCompleted])])
        ]
        for (name, steps) in cases {
            var tracker = SleepAgentTracker()
            for (index, step) in steps.enumerated() {
                let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(index * 2))
                let events = tracker.observe([step.0], projects: ["workspace": "project"], now: now)
                XCTAssertEqual(events.map(\.kind), step.1, "\(name), step \(index)")
                // Polling identical summaries must not synthesize another incident.
                XCTAssertTrue(tracker.observe([step.0], projects: [:], now: now).isEmpty, name)
            }
        }
    }

    func testDisappearanceClearsTurnEvidenceAndInferredInterruptionKeepsObservedTurnID() {
        var tracker = SleepAgentTracker()
        let now = Date()
        var working = snapshot("working", turn: "t2", lastTurn: "t1")
        working.runtimeIssue = .init(id: UUID(), at: "2026-11-17T00:00:00Z", willRetry: false, turnId: "t2")
        _ = tracker.observe([working], projects: [:], now: now)
        let interrupted = tracker.observe([snapshot("interrupted", lastTurn: "t1", outcome: "completed")],
                                          projects: [:], now: now)
        XCTAssertEqual(interrupted.map(\.kind), [.agentInterrupted])
        XCTAssertEqual(interrupted.first?.turnID, "t2")
        XCTAssertEqual(interrupted.first?.source, .inference)
        XCTAssertEqual(interrupted.first?.reason, .causeUnknown)
        _ = tracker.observe([working], projects: [:], now: now)
        XCTAssertTrue(tracker.observe([], projects: [:], now: now).isEmpty)
        let restored = tracker.observe([snapshot("idle", lastTurn: "t2", outcome: "completed")],
                                       projects: [:], now: now)
        XCTAssertEqual(restored.map(\.kind), [.agentCompleted])
    }

    func testCompletedTurnBeforeTerminalClosureIsNotAnInterruption() {
        for status in ["working", "waiting"] {
            var tracker = SleepAgentTracker()
            let now = Date()
            _ = tracker.observe([snapshot(status, turn: "turn1")], projects: [:], now: now)
            let events = tracker.observe(
                [snapshot("interrupted", lastTurn: "turn1", outcome: "completed")],
                projects: ["workspace": "project"], now: now.addingTimeInterval(2))
            XCTAssertEqual(events.map(\.kind), [.agentCompleted], status)
            XCTAssertEqual(events.first?.turnID, "turn1")
            XCTAssertEqual(events.first?.projectID, "project")
            XCTAssertTrue(tracker.observe([snapshot("working", turn: "turn2")],
                                          projects: [:], now: now).isEmpty)
            XCTAssertEqual(tracker.observe([snapshot("idle", lastTurn: "turn2", outcome: "completed")],
                                           projects: [:], now: now).map(\.kind), [.agentCompleted])
        }
    }

    func testStaleCompletedMetadataDoesNotHideInterruptedActiveTurn() {
        for turn in [nil, "turn2"] as [String?] {
            var tracker = SleepAgentTracker()
            let now = Date()
            _ = tracker.observe([snapshot("working", turn: turn)], projects: [:], now: now)
            let events = tracker.observe(
                [snapshot("interrupted", lastTurn: turn == nil ? nil : "turn1", outcome: "completed")],
                projects: [:], now: now)
            XCTAssertEqual(events.map(\.kind), [.agentInterrupted])
        }
    }

    func testRestartRestorationOfCompletedSessionDoesNotInventInterruptionOrRecovery() {
        var tracker = SleepAgentTracker()
        let now = Date()
        let restored = snapshot("interrupted", lastTurn: "turn1", outcome: "completed")
        XCTAssertEqual(tracker.observe([restored], projects: [:], now: now).map(\.kind), [.agentUnknown])
        XCTAssertTrue(tracker.observe([restored], projects: [:], now: now).isEmpty)
        XCTAssertTrue(tracker.observe([snapshot("working", turn: "turn2")], projects: [:], now: now).isEmpty)
        XCTAssertEqual(tracker.observe([snapshot("idle", lastTurn: "turn2", outcome: "completed")],
                                       projects: [:], now: now).map(\.kind), [.agentCompleted])
    }

    func testAgentFailuresRetriesAndRecoveryDoNotConfuseWaitingWithFailure() throws {
        func agent(_ status: String, turn: String? = nil, last: String? = nil, lastTurn: String = "turn1", channel: String? = "connected") throws -> SleepAgentState {
            let value: [String: Any] = ["id":"session", "terminalId":"terminal", "workspaceId":"workspace", "status":status,
                                        "turnId":turn as Any? ?? NSNull(), "lastTurnId":last == nil ? NSNull() : lastTurn as Any,
                                        "lastTurnStatus":last as Any? ?? NSNull(), "channelState":channel as Any? ?? NSNull()]
            return try JSONDecoder().decode(SleepAgentState.self, from: JSONSerialization.data(withJSONObject: value))
        }
        var tracker = SleepAgentTracker()
        let now = Date()
        func observe(_ status: String, turn: String? = nil, last: String? = nil, lastTurn: String = "turn1") throws -> [SleepHistoryEvent] {
            tracker.observe([try agent(status, turn: turn, last: last, lastTurn: lastTurn)], projects: ["workspace":"project"], now: now)
        }
        _ = try observe("working", turn: "turn1")
        let waiting = try observe("waiting", turn: "turn1")
        XCTAssertEqual(waiting.map(\.kind), [.agentWaiting])
        XCTAssertEqual(try observe("idle", last: "completed").map(\.kind), [.agentCompleted])
        let failure = try observe("failed", last: "failed")
        XCTAssertEqual(failure.map(\.kind), [.agentFailed])
        XCTAssertEqual(failure.first?.projectID, "project")
        XCTAssertEqual(failure.first?.sessionID, "session")
        let retry = try observe("working", turn: "turn2")
        XCTAssertTrue(retry.isEmpty)
        XCTAssertEqual(try observe("idle", last: "completed", lastTurn: "turn2").map(\.kind), [.agentCompleted])
        XCTAssertTrue(try observe("idle", last: "completed", lastTurn: "turn2").isEmpty)
        XCTAssertEqual(try observe("interrupted").map(\.kind), [.agentUnknown])
        _ = try observe("working", turn: "turn3")
        XCTAssertEqual(try observe("interrupted").map(\.kind), [.agentInterrupted])
        let disconnected = tracker.observe([try agent("interrupted", channel: "unavailable")], projects: [:], now: now)
        XCTAssertEqual(disconnected.map(\.kind), [.providerDown])
    }
}
