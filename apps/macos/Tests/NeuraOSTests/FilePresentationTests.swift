import XCTest
import AppKit
@testable import NeuraOS

final class FilePresentationTests: XCTestCase {
    func testFilesOpenAlongsideTerminalsAndDeduplicateByFullPath() throws {
        let terminal = WorkspaceTab(kind: "codex", terminalId: "pty")
        var layout = WorkspaceTabState(tabs: [terminal], selectedId: terminal.id)
        layout.openFile("docs/README.md")
        let first = layout.selectedId
        layout.openFile("README.md")
        XCTAssertEqual(layout.tabs.count, 3)
        layout.openFile("docs/README.md")
        XCTAssertEqual(layout.selectedId, first)
        XCTAssertEqual(layout.tabs.count, 3)
        XCTAssertEqual(layout.tabs.first, terminal)
        let restored = try JSONDecoder().decode(WorkspaceTabState.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored.tabs, layout.tabs)
        XCTAssertEqual(restored.selectedId, first)
        let old = try JSONDecoder().decode(WorkspaceTab.self, from: Data(#"{"id":"old","kind":"files","number":1}"#.utf8))
        XCTAssertNil(old.filePath)
    }

    func testPresentationTypes() {
        XCTAssertTrue(FilePresentation.isMarkdown("README.MD"))
        for path in ["photo.png", "scan.pdf", "movie.mp4", "audio.mp3", "document.docx", "sheet.xlsx"] {
            XCTAssertTrue(FilePresentation.prefersPreview(path), path)
        }
        for path in ["notes.txt", "source.swift", "config.json", "README.md"] {
            XCTAssertFalse(FilePresentation.prefersPreview(path), path)
        }
    }

    func testPreviewCannotEscapeWorkspaceThroughSymlinkOrTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: root)}
        let file = root.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try FilePresentation.previewURL(root: root.path, path: "note.txt"), file.resolvingSymlinksInPath())
        for path in ["../outside", "/etc/passwd", ".git/config", "missing"] {
            XCTAssertThrowsError(try FilePresentation.previewURL(root: root.path, path: path))
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try FilePresentation.previewURL(root: root.path, path: "escape"))
    }

    @MainActor func testWrappingTracksViewportAndCanBeDisabled() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        let editor = NSTextView(frame: scroll.bounds, textContainer: container)
        editor.isVerticallyResizable = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = editor
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        NativeTextEditor.configureWrapping(editor, in: scroll, enabled: true)
        XCTAssertTrue(editor.textContainer!.widthTracksTextView)
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(editor.textContainer!.containerSize.width, 400)
        editor.string = String(repeating: "long text without a newline ", count: 80)
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        let wideHeight = editor.frame.height
        XCTAssertGreaterThan(wideHeight, 300)
        scroll.setFrameSize(NSSize(width: 180, height: 300))
        NativeTextEditor.configureWrapping(editor, in: scroll, enabled: true)
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        XCTAssertGreaterThan(editor.frame.height, wideHeight)
        NativeTextEditor.configureWrapping(editor, in: scroll, enabled: false)
        XCTAssertFalse(editor.textContainer!.widthTracksTextView)
        XCTAssertTrue(editor.isHorizontallyResizable)
        XCTAssertTrue(scroll.hasHorizontalScroller)
    }
}
