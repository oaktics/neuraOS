import XCTest
import AppKit
import SwiftTerm
@testable import NeuraOS

final class TerminalLifecycleTests: XCTestCase {
    @MainActor private func renderer() -> (NativeTerminal.Coordinator, TerminalView) {
        _ = NSApplication.shared
        let record = TerminalRecord(id: "test-only", workspaceId: "test", provider: "shell", status: "running", cols: 100, rows: 30)
        let coordinator = NativeTerminal.Coordinator(terminal: record, api: DaemonClient(), onError: {_ in XCTFail("Unexpected API call")})
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        coordinator.view = view
        view.terminalDelegate = coordinator
        coordinator.setVisible(true)
        return (coordinator, view)
    }
    private func output(_ text: String, cursor: Int) -> TerminalOutput {
        TerminalOutput(data: text, chunks: [TerminalChunk(data: text, cols: nil, rows: nil)], cursor: cursor, more: false, status: "running", cols: 100, rows: 30)
    }
    @MainActor func testSwitchesRetainEmulatorCursorAndScrollback() {
        let (session, view) = renderer()
        session.apply(output((0..<100).map {"line-\($0)\r\n"}.joined(), cursor: 256), to: view)
        let emulator = view.getTerminal()
        view.scroll(toPosition: 0)
        XCTAssertTrue(view.canScroll)
        let position = view.scrollPosition
        XCTAssertEqual(position, 0)
        for _ in 0..<100 {session.setVisible(false); session.setVisible(true)}
        XCTAssertTrue(view.getTerminal() === emulator)
        XCTAssertEqual(session.cursor, 256)
        XCTAssertTrue(session.caughtUp)
        XCTAssertEqual(view.scrollPosition, position)
    }
    @MainActor func testHiddenOutputAdvancesSameSessionWithoutInputOrResize() {
        let (session, view) = renderer()
        session.apply(output("before\r\n", cursor: 1), to: view)
        session.setVisible(false)
        session.sizeChanged(source: view, newCols: 120, newRows: 40)
        session.send(source: view, data: Array("wrong workspace".utf8)[...])
        XCTAssertNil(session.pendingSize)
        XCTAssertTrue(session.pendingInput.isEmpty)
        session.apply(output("background\r\n", cursor: 2), to: view)
        XCTAssertEqual(session.cursor, 2)
        XCTAssertTrue(view.isHidden)
        session.setVisible(true)
        XCTAssertEqual(session.cursor, 2)
        XCTAssertEqual(session.pendingSize?.0, 120)
        XCTAssertEqual(session.pendingSize?.1, 40)
        XCTAssertFalse(view.isHidden)
    }
    @MainActor func testRapidSwitchCannotFocusHiddenTerminal() async {
        let (session, view) = renderer()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        session.apply(output("ready", cursor: 1), to: view)
        session.setVisible(false)
        for _ in 0..<5 {await Task.yield()}
        XCTAssertFalse(window.firstResponder === view)
        XCTAssertTrue(view.isHidden)
    }
    @MainActor func testStoppedTerminalRejectsInputAndDismantleCancelsPolling() {
        let (session, view) = renderer()
        session.caughtUp = true
        session.running = false
        session.send(source: view, data: Array("ignored".utf8)[...])
        XCTAssertTrue(session.pendingInput.isEmpty)
        // No network request can run before this main-actor task is cancelled.
        session.start()
        let task = session.polling
        NativeTerminal.dismantleNSView(view, coordinator: session)
        XCTAssertTrue(task?.isCancelled == true)
        XCTAssertNil(session.polling)
        XCTAssertFalse(session.visible)
        XCTAssertNil(view.terminalDelegate)
    }
    @MainActor func testLateInputFailureEndsWritesAndPreservesFinalOutput() {
        let (session, view) = renderer()
        session.caughtUp = true
        session.send(source: view, data: Array("queued input".utf8)[...])
        session.sizeChanged(source: view, newCols: 120, newRows: 40)
        XCTAssertFalse(session.pendingInput.isEmpty)
        XCTAssertTrue(session.handleLifecycleError(APIError(error: "terminal_stopped", message: "stopped")))
        XCTAssertFalse(session.running)
        XCTAssertTrue(session.pendingInput.isEmpty)
        XCTAssertNil(session.pendingSize)
        // An older model snapshot must not restart writes to the same terminal ID.
        session.updateStatus("running")
        session.send(source: view, data: Array("late input".utf8)[...])
        session.sizeChanged(source: view, newCols: 130, newRows: 45)
        session.apply(output("final output", cursor: 42), to: view)
        XCTAssertFalse(session.running)
        XCTAssertTrue(session.pendingInput.isEmpty)
        XCTAssertNil(session.pendingSize)
        XCTAssertEqual(session.cursor, 42)
        XCTAssertTrue(session.visible)
    }
    @MainActor func testDeletedTerminalEndsPollingWithoutReportingAnError() {
        let (session, _) = renderer()
        session.start()
        let task = session.polling
        XCTAssertTrue(session.handleLifecycleError(APIError(error: "terminal_missing", message: "missing")))
        XCTAssertTrue(task?.isCancelled == true)
        XCTAssertNil(session.polling)
        XCTAssertFalse(session.visible)
        XCTAssertFalse(session.running)
    }
    @MainActor func testExitOutputDiscardsEmulatorRepliesAndPendingInput() {
        let (session, view) = renderer()
        session.caughtUp = true
        session.pendingInput = "queued"
        let final = TerminalOutput(data: "", chunks: [TerminalChunk(data: "\u{1b}[6n", cols: nil, rows: nil)], cursor: 7, more: false, status: "exited", cols: 100, rows: 30)
        session.apply(final, to: view)
        XCTAssertFalse(session.running)
        XCTAssertTrue(session.pendingInput.isEmpty)
        XCTAssertNil(session.pendingSize)
    }
    @MainActor func testUnrelatedErrorsAreNotSuppressed() {
        let (session, _) = renderer()
        XCTAssertFalse(session.handleLifecycleError(APIError(error: "terminal_busy", message: "busy")))
        XCTAssertFalse(session.handleLifecycleError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(session.running)
    }

}
