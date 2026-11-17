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
        XCTAssertEqual(events.map(\.kind), [.providerRetry, .agentRecovered])
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
    func testAgentFailuresRetriesAndRecoveryDoNotConfuseWaitingWithFailure() throws {
        func agent(_ status: String, turn: String? = nil, last: String? = nil, channel: String? = "connected") throws -> SleepAgentState {
            let value: [String: Any] = ["id":"session", "terminalId":"terminal", "workspaceId":"workspace", "status":status,
                                        "turnId":turn as Any? ?? NSNull(), "lastTurnId":last == nil ? NSNull() : "turn1" as Any,
                                        "lastTurnStatus":last as Any? ?? NSNull(), "channelState":channel as Any? ?? NSNull()]
            return try JSONDecoder().decode(SleepAgentState.self, from: JSONSerialization.data(withJSONObject: value))
        }
        var tracker = SleepAgentTracker()
        let now = Date()
        func observe(_ status: String, turn: String? = nil, last: String? = nil) throws -> [SleepHistoryEvent] {
            tracker.observe([try agent(status, turn: turn, last: last)], projects: ["workspace":"project"], now: now)
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
        XCTAssertEqual(retry.first?.kind, .agentRetry)
        XCTAssertEqual(retry.first?.source, .inference)
        XCTAssertEqual(try observe("idle", last: "completed").map(\.kind), [.agentRecovered])
        XCTAssertTrue(try observe("idle", last: "completed").isEmpty)
        XCTAssertEqual(try observe("interrupted").map(\.kind), [.agentUnknown])
        _ = try observe("working", turn: "turn3")
        XCTAssertEqual(try observe("interrupted").map(\.kind), [.agentInterrupted])
        let disconnected = tracker.observe([try agent("interrupted", channel: "unavailable")], projects: [:], now: now)
        XCTAssertEqual(disconnected.map(\.kind), [.providerDown])
    }
}
