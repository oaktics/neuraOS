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
}
