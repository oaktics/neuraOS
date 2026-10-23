import XCTest
@testable import NeuraOS

final class AgentNotificationTests: XCTestCase {
    private func terminal(_ id: String = "t", event: String, provider: String = "codex", kind: String = "completed") -> TerminalRecord {
        TerminalRecord(id: id, workspaceId: "w", provider: provider, status: "running", cols: 80, rows: 24,
                       notification: AgentNotificationEvent(id: event, kind: kind, createdAt: "2026-10-23T00:00:00Z"))
    }
    func testBaselineDeduplicationAndReconnect() {
        var cursor = AgentNotificationCursor()
        XCTAssertTrue(cursor.consume([terminal(event: "old")]).isEmpty)
        XCTAssertEqual(cursor.consume([terminal(event: "new")]).map(\.id), ["t"])
        XCTAssertTrue(cursor.consume([terminal(event: "new")]).isEmpty)
        XCTAssertTrue(cursor.consume([]).isEmpty)
        XCTAssertTrue(cursor.consume([terminal(event: "new")]).isEmpty)
        XCTAssertEqual(cursor.consume([terminal(event: "next")]).count, 1)
    }
    func testIndependentProvidersAndUnknownKinds() {
        var cursor = AgentNotificationCursor()
        _ = cursor.consume([])
        XCTAssertEqual(cursor.consume([terminal("a", event: "1"), terminal("b", event: "2", provider: "claude", kind: "waiting")]).count, 2)
        XCTAssertTrue(cursor.consume([terminal("c", event: "3", provider: "shell"), terminal("d", event: "4", kind: "future")]).isEmpty)
    }
}
