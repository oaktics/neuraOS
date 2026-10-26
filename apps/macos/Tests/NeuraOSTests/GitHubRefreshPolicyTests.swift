import XCTest
@testable import NeuraOS

final class GitHubRefreshPolicyTests: XCTestCase {
    func testVisibleSelectionAndMissingPR() {
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "OPEN", checks: []), 60)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "OPEN", checks: [], selected: false), 120)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: nil, checks: []), 60)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: nil, checks: [], selected: false), 900)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "CLOSED", checks: []), 900)
    }
    func testMergedPRKeepsPollingUntilEveryCheckIsTerminal() {
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "MERGED", checks: ["FAILURE", "IN_PROGRESS"]), 60)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "MERGED", checks: ["NEW_STATE"]), 60)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "MERGED", checks: ["SUCCESS", "CANCELLED"]), 900)
        XCTAssertEqual(GitHubRefreshPolicy.interval(state: "MERGED", checks: []), 900)
    }
    func testFailureBackoffIsBounded() {
        XCTAssertEqual((1...6).map {GitHubRefreshPolicy.retryDelay(failures: $0)}, [60, 120, 240, 480, 900, 900])
    }
}
