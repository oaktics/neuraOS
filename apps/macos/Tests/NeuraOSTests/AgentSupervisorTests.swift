import XCTest
@testable import NeuraOS

final class AgentSupervisorTests: XCTestCase {
    func testStoppedSessionsAreHiddenButRecoverable() {
        for status in ["idle", "working", "waiting", "interrupted", "failed"] {
            let agent = ManagedAgent(id: "task", terminalId: "terminal", workspaceId: "workspace", name: "Worker", status: status, updatedAt: "now", turnId: nil, lastTurnStatus: nil, summary: nil, pending: [], requests: [])
            // Terminal liveness, not the last turn outcome, determines visibility.
            XCTAssertFalse(agent.isVisible(runningTerminalIDs: [], includeStopped: false))
            XCTAssertTrue(agent.isVisible(runningTerminalIDs: [], includeStopped: true))
            XCTAssertTrue(agent.isVisible(runningTerminalIDs: ["terminal"], includeStopped: false))
            XCTAssertFalse(agent.isVisible(runningTerminalIDs: ["replacement-terminal"], includeStopped: false))
        }
    }
    func testTaskStatusDoesNotCallAnIdleAgentFinished() throws {
        let data = Data(#"{"id":"task","terminalId":"terminal","workspaceId":"workspace","name":"Worker","status":"idle","updatedAt":"now","pending":[],"requests":[],"lastTurnStatus":"completed"}"#.utf8)
        let agent = try JSONDecoder().decode(ManagedAgent.self, from: data)
        XCTAssertEqual(agent.statusLabel, "次の指示待ち")
        XCTAssertEqual(agent.lastTurnStatus, "completed")
    }
    func testConversationDisplaysUserAgentAndCommandEvidence() throws {
        let data = Data(#"{"agent":{"id":"task","terminalId":"terminal","workspaceId":"workspace","name":"Worker","status":"working","updatedAt":"now","pending":[],"requests":[]},"history":{"data":[{"id":"turn","status":"inProgress","items":[{"id":"user","type":"userMessage","content":[{"type":"text","text":"Fix tests"}]},{"id":"command","type":"commandExecution","command":"pnpm test","aggregatedOutput":"Passed"},{"id":"reply","type":"agentMessage","text":"Done"}]}],"nextCursor":"older"}}"#.utf8)
        let value = try JSONDecoder().decode(AgentConversation.self, from: data)
        XCTAssertEqual(value.history.data[0].items.map(\.display), ["Fix tests", "pnpm test\nPassed", "Done"])
        XCTAssertEqual(value.history.nextCursor, "older")
    }
    func testQuestionRequestPreservesStringAndNumericIDs() throws {
        let numeric = Data(#"{"id":42,"method":"item/tool/requestUserInput","params":{"questions":[{"id":"q","question":"Which approach?","options":[{"label":"A","description":"First"}]}]}}"#.utf8)
        let question = try JSONDecoder().decode(AgentQuestionRequest.self, from: numeric)
        XCTAssertEqual(question.id, .number(42))
        XCTAssertEqual(question.params.questions?.first?.options?.first?.label, "A")
        let string = Data(#"{"id":"request-1","method":"other","params":{}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentQuestionRequest.self, from: string).id, .string("request-1"))
    }
    private func historyPage(_ ids: ClosedRange<Int>, cursor: String?, status: String = "completed") -> AgentConversation.History {
        .init(data: ids.reversed().map {AgentConversation.Turn(id: String($0), status: status, items: [])}, nextCursor: cursor)
    }
    func testRefreshKeepsTurnsThatLeaveTheNewestPage() {
        var window = AgentHistoryWindow()
        window.refresh(historyPage(21...40, cursor: "before21"))
        window.prepend(historyPage(1...20, cursor: nil), expectedCursor: "before21")
        window.refresh(historyPage(22...41, cursor: "before22", status: "updated"))
        XCTAssertEqual(window.turns.map(\.id), (1...41).map(String.init))
        XCTAssertEqual(window.turns.last?.status, "updated")
        XCTAssertNil(window.nextCursor)
    }
    func testDisconnectedRefreshResetsCursorAndRejectsOldPaginationResponse() {
        var window = AgentHistoryWindow()
        window.refresh(historyPage(21...40, cursor: "before21"))
        window.refresh(historyPage(81...100, cursor: "before81"))
        window.prepend(historyPage(1...20, cursor: nil), expectedCursor: "before21")
        XCTAssertEqual(window.turns.map(\.id), (81...100).map(String.init))
        XCTAssertEqual(window.nextCursor, "before81")
        window.prepend(historyPage(61...80, cursor: "before61"), expectedCursor: "before81")
        window.refresh(historyPage(82...101, cursor: "before82"))
        XCTAssertEqual(window.turns.map(\.id), (61...101).map(String.init))
        XCTAssertEqual(window.nextCursor, "before61")
    }

}
