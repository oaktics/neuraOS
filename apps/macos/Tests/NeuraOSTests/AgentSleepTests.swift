import XCTest
import SleepControl
@testable import NeuraOS

final class AgentSleepTests: XCTestCase {
    private func terminal(_ provider: String, _ activity: String?, _ status: String = "running", workspace: String = "w") -> TerminalRecord {
        TerminalRecord(id: UUID().uuidString, workspaceId: workspace, provider: provider, status: status, cols: 80, rows: 24, activity: activity)
    }
    func testWorkInAnotherWorkspaceWinsOverWaitingAndStoppedTabs() {
        let decision = AgentSleepPolicy.decision([
            terminal("claude", "waiting"), terminal("codex", "working", workspace: "hidden"),
            terminal("codex", "working", "exited"), terminal("shell", "working")], connected: true)
        XCTAssertTrue(decision.working); XCTAssertFalse(decision.complete)
        let finished = AgentSleepPolicy.decision([terminal("claude", "waiting"), terminal("codex", "idle"), terminal("shell", "working")], connected: true)
        XCTAssertFalse(finished.working); XCTAssertTrue(finished.complete)
    }
    func testUnknownOrDisconnectedCannotBeMistakenForCompletion() {
        for activity in [nil, "future", "unknown"] as [String?] {
            let decision = AgentSleepPolicy.decision([terminal("codex", activity)], connected: true)
            XCTAssertFalse(decision.working); XCTAssertFalse(decision.complete)
        }
        let disconnected = AgentSleepPolicy.decision([terminal("codex", "working")], connected: false)
        XCTAssertFalse(disconnected.working); XCTAssertFalse(disconnected.complete)
        XCTAssertTrue(AgentSleepPolicy.decision([terminal("claude", "working", "exited")], connected: true).complete)
    }
    func testCompletionDebounceResetsWhenWorkResumesAndDisconnectHasGrace() {
        var policy = SleepDebounce()
        XCTAssertFalse(policy.shouldRelease(state: "done", now: 0))
        XCTAssertFalse(policy.shouldRelease(state: "work", now: 4))
        XCTAssertFalse(policy.shouldRelease(state: "done", now: 5))
        XCTAssertTrue(policy.shouldRelease(state: "done", now: 10))
        XCTAssertFalse(policy.shouldRelease(state: "unknown", now: 11))
        XCTAssertFalse(policy.shouldRelease(state: "unknown", now: 40))
        XCTAssertTrue(policy.shouldRelease(state: "unknown", now: 41))
        XCTAssertFalse(policy.shouldRelease(state: "work", now: 42))
    }
    func testLeaseRejectsStaleWrongOwnerTokenSymlinkAndMalformedInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {try? FileManager.default.removeItem(at: directory)}
        let file = directory.appendingPathComponent("lease"), link = directory.appendingPathComponent("link")
        let token = UUID().uuidString
        let heartbeat = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try AgentSleepController.leaseValue(token: token, state: "work", awakeNanoseconds: heartbeat).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SleepLease.read(path: file.path, owner: getuid(), token: token), "work")
        XCTAssertNil(SleepLease.read(path: file.path, owner: getuid() + 1, token: token))
        XCTAssertNil(SleepLease.read(path: file.path, owner: getuid(), token: "other"))
        XCTAssertNil(SleepLease.read(path: file.path, owner: getuid(), token: token, awakeNanoseconds: heartbeat + 15_000_000_000))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(SleepLease.read(path: link.path, owner: getuid(), token: token))
        try "\(token)\nwork; touch /tmp/invalid\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(SleepLease.read(path: file.path, owner: getuid(), token: token))
        XCTAssertNil(SleepLease.read(path: directory.path, owner: getuid(), token: token))
    }
    func testLeaseSurvivesSystemSleepButExpiresWhenAppStopsWhileAwake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {try? FileManager.default.removeItem(at: directory)}
        let file = directory.appendingPathComponent("lease"), token = UUID().uuidString
        let heartbeat: UInt64 = 100_000_000_000
        for state in ["work", "done", "unknown"] {
            try AgentSleepController.leaseValue(token: token, state: state, awakeNanoseconds: heartbeat)
                .write(to: file, atomically: true, encoding: .utf8)
            // An hour of system sleep ages mtime but not CLOCK_UPTIME_RAW.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
            XCTAssertEqual(SleepLease.read(path: file.path, owner: getuid(), token: token,
                                          awakeNanoseconds: heartbeat + 2_000_000_000), state)
            XCTAssertEqual(SleepLease.read(path: file.path, owner: getuid(), token: token,
                                          awakeNanoseconds: heartbeat + 14_999_999_999), state)
            // No new heartbeat after waking still expires at 15 awake seconds.
            XCTAssertNil(SleepLease.read(path: file.path, owner: getuid(), token: token,
                                        awakeNanoseconds: heartbeat + 15_000_000_000))
            XCTAssertNil(SleepLease.read(path: file.path, owner: getuid(), token: token,
                                        awakeNanoseconds: heartbeat - 1))
        }
        // The next heartbeat renews protection without new authorization.
        try AgentSleepController.leaseValue(token: token, state: "work", awakeNanoseconds: heartbeat + 20_000_000_000)
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SleepLease.read(path: file.path, owner: getuid(), token: token,
                                      awakeNanoseconds: heartbeat + 21_000_000_000), "work")
    }
    @MainActor func testSupervisorQuotesUntrustedPathsAndRestoresOnExit() {
        XCTAssertEqual(AgentSleepController.quote("a'b"), "'a'\\''b'")
        let command = AgentSleepController.supervisedCommand(helper: "/tmp/a ' b/helper", lease: "/tmp/lease", uid: 501, token: "token")
        XCTAssertTrue(command.contains("disablesleep 0"))
        XCTAssertTrue(command.contains("trap"))
    }
}
