import XCTest
import AppKit
import Observation
@testable import NeuraOS

final class AppVisibilityTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {lock.lock(); defer {lock.unlock()}; return value}
        func add() {lock.lock(); value += 1; lock.unlock()}
    }
    private final class State: @unchecked Sendable {var visible = true}

    // The Git and agent refresh loops key their task on this value. AppKit posts
    // occlusion notifications for every window; only a real transition may restart them.
    @MainActor func testOnlyRealOcclusionTransitionsInvalidateReaders() {
        let center = NotificationCenter()
        let state = State()
        let visibility = AppVisibility(center: center, read: {state.visible})
        XCTAssertTrue(visibility.visible)
        let invalidations = Counter()
        func observe() {
            withObservationTracking {_ = visibility.visible} onChange: {
                invalidations.add()
                Task { @MainActor in observe() }
            }
        }
        observe()
        for _ in 0..<1_000 {center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(invalidations.count, 0)
        XCTAssertTrue(visibility.visible)
        state.visible = false
        for _ in 0..<1_000 {center.post(name: NSApplication.didChangeOcclusionStateNotification, object: nil)}
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(invalidations.count, 1)
        XCTAssertFalse(visibility.visible)
        // Becoming frontmost re-evaluates too, without waiting for an occlusion change.
        state.visible = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(invalidations.count, 2)
        XCTAssertTrue(visibility.visible)
    }
}
