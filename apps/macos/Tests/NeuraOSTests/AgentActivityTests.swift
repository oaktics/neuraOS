import XCTest
@testable import NeuraOS

final class AgentActivityTests: XCTestCase {
    private func terminal(_ provider: String = "codex", _ activity: String?, status: String = "running") -> TerminalRecord {
        TerminalRecord(id: UUID().uuidString, workspaceId: "w", provider: provider, status: status, cols: 80, rows: 24, activity: activity)
    }
    func testAttentionWinsOverWorkAndOldTabsDoNotPolluteSummary() {
        let summary = WorkspaceActivity(terminals: [terminal("codex", "working"), terminal("claude", "waiting"), terminal("codex", "waiting", status: "exited")], connected: true)
        XCTAssertEqual(summary.activity, .waiting)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.agents.count, 2)
        XCTAssertTrue(summary.help.contains("Codex: 作業中"))
        XCTAssertTrue(summary.help.contains("Claude Code: 回答・承認待ち"))
    }
    func testDisconnectedLegacyAndFutureStatesNeverLookIdle() {
        XCTAssertEqual(WorkspaceActivity(terminals: [terminal("codex", "working")], connected: false).activity, .unknown)
        XCTAssertEqual(WorkspaceActivity(terminals: [terminal("codex", nil)], connected: true).activity, .unknown)
        XCTAssertEqual(WorkspaceActivity(terminals: [terminal("codex", "future")], connected: true).activity, .unknown)
        XCTAssertEqual(WorkspaceActivity(terminals: [terminal("codex", "working", status: "interrupted")], connected: true).activity, .stopped)
        XCTAssertNil(WorkspaceActivity(terminals: [terminal("shell", nil)], connected: true).activity)
    }
    func testLegacyTerminalDecodesWithoutActivity() throws {
        let data = Data(#"{"id":"t","workspaceId":"w","provider":"codex","status":"running","cols":80,"rows":24}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TerminalRecord.self, from: data).activity)
    }
}
