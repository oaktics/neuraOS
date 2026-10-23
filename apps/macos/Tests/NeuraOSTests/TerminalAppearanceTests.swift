import XCTest
import AppKit
import SwiftTerm
@testable import NeuraOS

final class TerminalAppearanceTests: XCTestCase {
    @MainActor func testLiveAppearanceChangesRefreshDefaultsWithoutResettingSession() {
        _ = NSApplication.shared
        let record = TerminalRecord(id: "appearance-test", workspaceId: "test", provider: "codex", status: "running", cols: 100, rows: 30)
        let session = NativeTerminal.Coordinator(terminal: record, api: DaemonClient(), onError: {_ in XCTFail("Unexpected API call")})
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.updateAppearanceColors()
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        defer {window.contentView = nil}
        window.contentView = view
        view.terminalDelegate = session
        session.view = view
        session.setVisible(true)
        session.caughtUp = true
        session.cursor = 42
        let emulator = view.getTerminal()
        view.feed(text: (0..<100).map {"line-\($0)\r\n"}.joined())
        view.scroll(toPosition: 0)
        let scrollPosition = view.scrollPosition

        // Change the owning window, just as AppKit does for a system theme change.
        for hidden in [false, true] {
            session.setVisible(!hidden)
            for dark in [false, true, false] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.displayIfNeeded()
                let background = view.nativeBackgroundColor.usingColorSpace(.deviceRGB)!
                let foreground = view.nativeForegroundColor.usingColorSpace(.deviceRGB)!
                XCTAssertEqual(background.redComponent, dark ? 0.105 : 0.985, accuracy: 0.001)
                XCTAssertEqual(background.greenComponent, background.redComponent, accuracy: 0.001)
                XCTAssertTrue(dark ? foreground.redComponent > background.redComponent : foreground.redComponent < background.redComponent)

                // Codex's OSC startup probe must receive the current concrete palette.
                session.pendingInput = ""
                session.applying = true
                view.feed(text: "\u{1b}]10;?\u{7}\u{1b}]11;?\u{7}")
                session.applying = false
                let fg = emulator.foregroundColor
                let bg = emulator.backgroundColor
                let hex: (UInt16) -> String = {String(format: "%04x", Int($0))}
                XCTAssertTrue(session.pendingInput.contains("10;rgb:\(hex(fg.red))/\(hex(fg.green))/\(hex(fg.blue))"))
                XCTAssertTrue(session.pendingInput.contains("11;rgb:\(hex(bg.red))/\(hex(bg.green))/\(hex(bg.blue))"))
                XCTAssertTrue(view.getTerminal() === emulator)
                XCTAssertEqual(session.cursor, 42)
                XCTAssertEqual(view.scrollPosition, scrollPosition)
                XCTAssertEqual(view.isHidden, hidden)
            }
        }
    }
}
