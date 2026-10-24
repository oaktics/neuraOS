import XCTest
@testable import NeuraOS

final class AgentNotificationTests: XCTestCase {
    private func event(_ sequence: Int, kind: String = "completed", provider: String = "codex") -> AgentNotificationEvent {
        AgentNotificationEvent(id: "event-\(sequence)", sequence: sequence, terminalId: "t", workspaceId: "w", provider: provider, kind: kind, createdAt: "2026-10-23T00:00:00Z")
    }
    func testBaselineAndReconnectNeverReplayConsumedEvents() {
        var cursor = AgentNotificationCursor()
        cursor.baseline(10)
        let page = AgentNotificationPage(events: [event(9), event(11), event(12)], cursor: 12, more: false)
        XCTAssertEqual(cursor.pending(page).map(\.sequence), [11, 12])
        cursor.acknowledge(11)
        // Reconnect must not reset to the latest snapshot revision and lose event 12.
        cursor.baseline(30)
        XCTAssertEqual(cursor.pending(page).map(\.sequence), [12])
        cursor.acknowledge(12)
        cursor.acknowledge(9)
        XCTAssertTrue(cursor.pending(page).isEmpty)
        XCTAssertEqual(cursor.after, 12)
    }
    func testRapidWaitingAndCompletionAreBothDeliveredInOrder() {
        var cursor = AgentNotificationCursor()
        cursor.baseline(0)
        for provider in ["codex", "claude"] {
            let start = cursor.after ?? 0
            let page = AgentNotificationPage(events: [event(start + 2, provider: provider), event(start + 1, kind: "waiting", provider: provider)], cursor: start + 2, more: false)
            XCTAssertEqual(cursor.pending(page).map(\.kind), ["waiting", "completed"])
            // A failed delivery leaves the event pending until explicitly acknowledged.
            XCTAssertEqual(cursor.pending(page).count, 2)
            cursor.acknowledge(start + 1)
            XCTAssertEqual(cursor.pending(page).map(\.kind), ["completed"])
            cursor.acknowledge(page.cursor)
            XCTAssertTrue(cursor.pending(page).isEmpty)
        }
    }
}
