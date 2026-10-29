import XCTest
@testable import NeuraOS

final class DaemonRestartTests: XCTestCase {
    @MainActor func testCancelAndDuplicateNeverRestart() async {
        let subject = DaemonRestart()
        var calls = 0
        await subject.perform(confirmed: false, restart: {calls += 1}, reconnect: {true})
        XCTAssertEqual(calls, 0)
        await subject.perform(confirmed: true, restart: {
            calls += 1
            XCTAssertTrue(subject.busy)
            await subject.perform(confirmed: true, restart: {calls += 1}, reconnect: {true})
        }, reconnect: {true})
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(subject.busy)
        XCTAssertTrue(subject.message?.contains("再接続しました") == true)
    }
    @MainActor func testLaunchSuccessDoesNotMeanConnectionSuccessAndCanRetry() async {
        let subject = DaemonRestart()
        await subject.perform(confirmed: true, timeout: .zero, restart: {}, reconnect: {false})
        XCTAssertTrue(subject.message?.contains("再接続に失敗") == true)
        XCTAssertFalse(subject.busy)
        await subject.perform(confirmed: true, restart: {}, reconnect: {true})
        XCTAssertTrue(subject.message?.contains("再接続しました") == true)
        await subject.perform(confirmed: true, restart: {throw APIError(error: "fixture", message: "launch failure")}, reconnect: {XCTFail(); return true})
        XCTAssertTrue(subject.message?.contains("launch failure") == true)
        XCTAssertFalse(subject.busy)
    }
    @MainActor func testOfflineTransientConnectionRecovers() async {
        let subject = DaemonRestart()
        var tries = 0
        await subject.perform(confirmed: true, restart: {}, reconnect: {
            tries += 1
            if tries == 1 {throw APIError(error: "offline", message: "fixture offline")}
            return true
        })
        XCTAssertEqual(tries, 2)
        XCTAssertTrue(subject.message?.contains("再接続しました") == true)
    }
}
