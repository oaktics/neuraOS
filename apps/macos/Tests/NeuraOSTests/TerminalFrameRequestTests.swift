import XCTest
import SwiftTerm
@testable import NeuraOS

final class TerminalFrameRequestTests: XCTestCase {
    private func time(_ seconds: TimeInterval) -> Date {Date(timeIntervalSinceReferenceDate: seconds)}

    func testPresentedFrameAnswersTheRequestsItDrew() {
        var ledger = MetalFrameRequestLedger()
        XCTAssertNil(ledger.oldestUnanswered)
        ledger.request(at: time(0))
        let frame = ledger.drawBegan()
        ledger.presented(generation: frame)
        XCTAssertNil(ledger.oldestUnanswered)
    }

    // R1 -> frame 1 begins -> R2 -> frame 1 presented: R2 was not drawn and stays open.
    func testRequestMadeWhileAFrameIsOnItsWayStaysOpen() {
        var ledger = MetalFrameRequestLedger()
        ledger.request(at: time(0))
        let first = ledger.drawBegan()
        ledger.request(at: time(2))
        ledger.presented(generation: first)
        XCTAssertEqual(ledger.oldestUnanswered, time(2))
        let second = ledger.drawBegan()
        ledger.presented(generation: second)
        XCTAssertNil(ledger.oldestUnanswered)
    }

    func testSteadyOutputDoesNotMoveTheOldestRequest() {
        var ledger = MetalFrameRequestLedger()
        for tick in 0..<1_000 {ledger.request(at: time(Double(tick) * 0.05))}
        XCTAssertEqual(ledger.oldestUnanswered, time(0))
    }

    // The renderer keeps drawing but nothing reaches the screen.
    func testFramesThatNeverPresentKeepTheFirstRequestOpen() {
        var ledger = MetalFrameRequestLedger()
        for tick in 0..<1_000 {
            ledger.request(at: time(Double(tick)))
            _ = ledger.drawBegan()
        }
        XCTAssertEqual(ledger.oldestUnanswered, time(0))
    }

    // Far more generations than are tracked one by one, then an old frame is presented.
    func testRequestAfterManyUnpresentedFramesSurvivesAnOldPresentation() {
        var ledger = MetalFrameRequestLedger()
        var last: UInt64 = 0
        for tick in 0..<1_000 {
            ledger.request(at: time(Double(tick)))
            last = ledger.drawBegan()
        }
        ledger.request(at: time(5_000))
        ledger.presented(generation: last)
        XCTAssertEqual(ledger.oldestUnanswered, time(5_000))
    }

    func testMergedGenerationsStayOpenUntilTheLaterOneIsPresented() {
        var ledger = MetalFrameRequestLedger()
        var generations: [UInt64] = []
        for tick in 0..<1_000 {
            ledger.request(at: time(Double(tick)))
            generations.append(ledger.drawBegan())
        }
        // Presenting only the very first frame must not close requests drawn later.
        ledger.presented(generation: generations[0])
        XCTAssertNotNil(ledger.oldestUnanswered)
        ledger.presented(generation: generations[999])
        XCTAssertNil(ledger.oldestUnanswered)
    }

    func testRecoveryEscalatesWhileTheSameRequestStaysOpen() {
        var recovery = TerminalFrameRecovery()
        XCTAssertEqual(recovery.step(oldest: nil, now: time(0), deadline: 1), .none)
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(0.5), deadline: 1), .wait(0.5))
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(1), deadline: 1), .redraw)
        recovery.watch(time(0))
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(2), deadline: 1), .rebuild)
        // The rebuild starts a new ledger; its own redraw is the request now watched.
        recovery.watch(time(2))
        XCTAssertEqual(recovery.step(oldest: time(2), now: time(4), deadline: 1), .fallback)
    }

    // Rebuild at t0 -> its frame is presented -> a new request stalls -> next check at t0+2.
    // The new stall has waited past the deadline, but it is not the one that was rebuilt for.
    func testNewStallAfterASuccessfulRebuildStartsOver() {
        var recovery = TerminalFrameRecovery()
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(1), deadline: 1), .redraw)
        recovery.watch(time(0))
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(2), deadline: 1), .rebuild)
        recovery.watch(time(2))
        XCTAssertEqual(recovery.step(oldest: time(2.25), now: time(4), deadline: 1), .redraw)
    }

    func testNewStallAfterASuccessfulRedrawStartsOver() {
        var recovery = TerminalFrameRecovery()
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(1), deadline: 1), .redraw)
        recovery.watch(time(0))
        XCTAssertEqual(recovery.step(oldest: time(1.25), now: time(3), deadline: 1), .redraw)
    }

    func testPostponedRebuildIsTriedAgain() {
        var recovery = TerminalFrameRecovery()
        _ = recovery.step(oldest: time(0), now: time(1), deadline: 1)
        recovery.watch(time(0))
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(2), deadline: 1), .rebuild)
        recovery.postponeRebuild()
        XCTAssertEqual(recovery.step(oldest: time(0), now: time(9), deadline: 1), .rebuild)
    }

    func testLatePresentationOfAnOlderFrameKeepsNewerRequests() {
        var ledger = MetalFrameRequestLedger()
        ledger.request(at: time(0))
        let first = ledger.drawBegan()
        ledger.request(at: time(1))
        let second = ledger.drawBegan()
        ledger.request(at: time(2))
        ledger.presented(generation: first)
        XCTAssertEqual(ledger.oldestUnanswered, time(1))
        ledger.presented(generation: second)
        XCTAssertEqual(ledger.oldestUnanswered, time(2))
    }
}
