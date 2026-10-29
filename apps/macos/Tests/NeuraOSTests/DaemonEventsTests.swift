import XCTest
@testable import NeuraOS

final class DaemonEventsTests: XCTestCase {
    @MainActor func testChangesDuringReplayRemainPendingAndCoalesce() async {
        let pulse = EventPulse()
        var events = pulse.stream.makeAsyncIterator()
        for _ in 0..<10_000 {pulse.signal()}
        let first: Void? = await events.next()
        XCTAssertNotNil(first)
        // A fetch starts after consuming the first wakeup. Updates during it
        // must survive until the consumer returns to waiting.
        pulse.signal(); pulse.signal()
        pulse.finish()
        let duringFetch: Void? = await events.next()
        let end: Void? = await events.next()
        XCTAssertNotNil(duringFetch)
        XCTAssertNil(end)
    }

    @MainActor func testCancellationReleasesAnIdleConsumer() async {
        let pulse = EventPulse()
        let consumer = Task { @MainActor in
            var events = pulse.stream.makeAsyncIterator()
            return await events.next() != nil
        }
        await Task.yield()
        consumer.cancel()
        let received = await consumer.value
        XCTAssertFalse(received)
    }

    func testInvalidationMessagesDecodeWithoutOutputPayload() throws {
        let message = try JSONDecoder().decode(DaemonEvents.Change.self,
            from: Data(#"{"type":"changed","state":true,"terminals":["a","b"]}"#.utf8))
        XCTAssertEqual(message.type, "changed")
        XCTAssertEqual(message.terminals, ["a", "b"])
        XCTAssertEqual(message.state, true)
    }
    @MainActor func testFeatureDowngradeWakesConsumersAndCanUpgradeAgain() async {
        let events = DaemonEvents(endpoint: URL(string: "http://127.0.0.1:1")!, dataDirectory: URL(fileURLWithPath: "/nonexistent"))
        var changes: [String] = []
        events.observe {changes.append($0.type)}
        events.configure(features: ["state.stream"])
        XCTAssertTrue(events.supported)
        events.configure(features: ["terminal.multiple"])
        XCTAssertFalse(events.supported)
        XCTAssertFalse(events.connected)
        XCTAssertEqual(changes, ["disconnected"])
        events.configure(features: ["state.stream"])
        XCTAssertTrue(events.supported)
        events.configure(features: nil)
        await Task.yield()
        XCTAssertFalse(events.supported)
        XCTAssertFalse(events.connected)
        XCTAssertEqual(changes, ["disconnected", "disconnected"])
    }
    @MainActor func testFailedDeliveryRetriesWithoutAnotherDaemonEvent() async {
        let retry = FailureRetry(base: 0.001)
        let recovered = expectation(description: "delivery recovered without state event")
        var attempts = 0
        var deliver: (@MainActor () -> Void)!
        deliver = {
            attempts += 1
            let failed = attempts < 3
            retry.update(failed: failed) {deliver()}
            if !failed {recovered.fulfill()}
        }
        deliver()
        await fulfillment(of: [recovered], timeout: 1)
        XCTAssertEqual(attempts, 3)
        deliver = nil
    }
    @MainActor func testSuccessfulDeliveryCancelsPendingRetry() async throws {
        let retry = FailureRetry(base: 0.001)
        var wakes = 0
        retry.update(failed: true) {wakes += 1}
        retry.update(failed: false) {wakes += 1}
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(wakes, 0)
    }

}
