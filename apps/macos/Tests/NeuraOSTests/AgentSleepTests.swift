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
    func testServiceRejectsMalformedRequestsAndCannotChoosePrivilegedOwner() {
        let token = UUID().uuidString
        XCTAssertTrue(SleepService.validRequest(lease: "/tmp/lease", token: token, owner: 501))
        XCTAssertFalse(SleepService.validRequest(lease: "/tmp/lease", token: token, owner: 0))
        XCTAssertFalse(SleepService.validRequest(lease: "relative", token: token, owner: 501))
        XCTAssertFalse(SleepService.validRequest(lease: "/tmp/lease\0suffix", token: token, owner: 501))
        XCTAssertFalse(SleepService.validRequest(lease: "/" + String(repeating: "x", count: 1024), token: token, owner: 501))
        XCTAssertFalse(SleepService.validRequest(lease: "/tmp/lease", token: "not-a-token", owner: 501))
    }
    func testCodeSigningRequirementFailsClosedForUnsignedPeer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: file)}
        try "unsigned".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SleepService.requirement(for: file))
        XCTAssertFalse(try SleepService.requirement(for: URL(fileURLWithPath: "/usr/bin/true")).isEmpty)
    }
    func testSessionRestoresBeforeSleepingAndCanResumeWithoutNewAuthorization() throws {
        let power = FakeSleepPower()
        let session = try SleepSession(power: power)
        _ = try session.step(state: "work", now: 0)
        _ = try session.step(state: "done", now: 1)
        _ = try session.step(state: "done", now: 6)
        XCTAssertEqual(power.actions, ["acquire", "release", "sleep"])
        _ = try session.step(state: "work", now: 7)
        try session.stop()
        XCTAssertEqual(power.actions, ["acquire", "release", "sleep", "acquire", "release"])
        try session.stop()
        XCTAssertEqual(power.actions.count, 5)
    }
    func testOpenLidAndDisconnectedSessionNeverForceSleep() throws {
        let power = FakeSleepPower(); power.lidClosed = false
        let session = try SleepSession(power: power)
        _ = try session.step(state: "work", now: 0)
        _ = try session.step(state: "done", now: 1)
        _ = try session.step(state: "done", now: 6)
        _ = try session.step(state: "work", now: 7)
        _ = try session.step(state: "unknown", now: 8)
        _ = try session.step(state: "unknown", now: 38)
        XCTAssertEqual(power.actions, ["acquire", "release", "acquire", "release"])
    }
    func testPartialAcquireAndFailedRestorationCanBeRetried() throws {
        let power = FakeSleepPower(); power.failAcquire = true
        let session = try SleepSession(power: power)
        XCTAssertThrowsError(try session.step(state: "work", now: 0))
        power.failRelease = true
        XCTAssertThrowsError(try session.stop())
        XCTAssertTrue(power.sleepDisabled)
        power.failRelease = false
        try session.stop()
        XCTAssertFalse(power.sleepDisabled)
    }
    func testUnsafePowerStopsWorkAndForeignOverrideIsNeverAdopted() throws {
        let power = FakeSleepPower(); power.sleepDisabled = true
        XCTAssertThrowsError(try SleepSession(power: power))
        XCTAssertTrue(power.actions.isEmpty)
        power.sleepDisabled = false
        let session = try SleepSession(power: power)
        _ = try session.step(state: "work", now: 0)
        power.unsafePower = true
        XCTAssertThrowsError(try session.step(state: "work", now: 1))
        try session.stop()
        XCTAssertEqual(power.actions, ["acquire", "release"])
    }
}

private final class FakeSleepPower: SleepPower {
    var sleepDisabled = false
    var lidClosed: Bool? = true
    var unsafePower = false
    var failAcquire = false
    var failRelease = false
    var actions: [String] = []
    func acquire() throws {
        actions.append("acquire"); sleepDisabled = true
        if failAcquire {throw SleepSessionError("acquire failed after mutation")}
    }
    func release() throws {
        actions.append("release")
        if failRelease {throw SleepSessionError("restore failed")}
        sleepDisabled = false
    }
    func sleepNow() throws {actions.append("sleep")}
}
