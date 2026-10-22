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
}
