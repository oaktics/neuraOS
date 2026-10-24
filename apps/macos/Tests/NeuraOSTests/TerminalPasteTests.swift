import XCTest
import AppKit
@testable import NeuraOS

final class TerminalPasteTests: XCTestCase {
    @MainActor func testFilePasteUsesQuotedPathsAndBracketedPasteWithoutSubmitting() {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/it's $(echo hi).pdf")]
        clipboard.writeObjects(urls as [NSURL])
        let expected = "'/tmp/a b.png' '/tmp/it'\"'\"'s $(echo hi).pdf' "
        XCTAssertEqual(NativeTerminalView.filePasteText(from: clipboard), expected)
        let record = TerminalRecord(id: "files-test", workspaceId: "test", provider: "codex", status: "running", cols: 100, rows: 30)
        let session = NativeTerminal.Coordinator(terminal: record, api: DaemonClient(), onError: { _ in XCTFail("Unexpected API call") })
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.terminalDelegate = session
        session.visible = true
        session.caughtUp = true
        view.feed(text: "\u{1b}[?2004h")
        for provider in ["codex", "claude", "shell"] {
            view.provider = provider
            session.pendingInput = ""
            XCTAssertTrue(view.pasteFiles(from: clipboard))
            XCTAssertEqual(session.pendingInput, "\u{1b}[200~" + expected + "\u{1b}[201~")
        }
        view.acceptsFileInput = { false }
        session.pendingInput = ""
        XCTAssertFalse(view.pasteFiles(from: clipboard))
        XCTAssertTrue(session.pendingInput.isEmpty)
    }

    @MainActor func testFilePasteRejectsNonFilesAndControlCharacters() {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.writeObjects([NSURL(string: "https://example.com/file.png")!])
        XCTAssertNil(NativeTerminalView.filePasteText(from: clipboard))
        clipboard.clearContents()
        clipboard.setString("ordinary text", forType: .string)
        XCTAssertNil(NativeTerminalView.filePasteText(from: clipboard))
        for character in ["\n", "\r", "\u{1b}", "\t"] {
            clipboard.clearContents()
            clipboard.writeObjects([URL(fileURLWithPath: "/tmp/bad" + character + "name") as NSURL])
            XCTAssertNil(NativeTerminalView.filePasteText(from: clipboard))
        }
    }

    @MainActor func testImagePasteSendsCodexShortcutThroughOrderedInput() {
        _ = NSApplication.shared
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        let record = TerminalRecord(id: "paste-test", workspaceId: "test", provider: "codex", status: "running", cols: 100, rows: 30)
        let session = NativeTerminal.Coordinator(terminal: record, api: DaemonClient(), onError: { _ in XCTFail("Unexpected API call") })
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.provider = "codex"
        view.terminalDelegate = session
        session.visible = true
        session.caughtUp = true
        // The shortcut must remain a key even when bracketed paste is enabled.
        view.feed(text: "\u{1b}[?2004h")
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            clipboard.clearContents()
            clipboard.setData(Data([1]), forType: type)
            clipboard.setString("image caption", forType: .string)
            session.pendingInput = ""
            XCTAssertTrue(view.pasteImage(from: clipboard))
            XCTAssertEqual(session.pendingInput, "\u{16}")
        }
        clipboard.clearContents()
        clipboard.setString("hello\nworld", forType: .string)
        session.pendingInput = ""
        XCTAssertFalse(view.pasteImage(from: clipboard))
        XCTAssertTrue(session.pendingInput.isEmpty)

        clipboard.clearContents()
        clipboard.setData(Data([1]), forType: .png)
        view.provider = "shell"
        session.pendingInput = ""
        XCTAssertFalse(view.pasteImage(from: clipboard))
        XCTAssertFalse(session.pendingInput.contains("\u{16}"))

        view.provider = "codex"
        session.running = false
        session.pendingInput = ""
        view.pasteImage(from: clipboard)
        XCTAssertTrue(session.pendingInput.isEmpty)
    }
}
