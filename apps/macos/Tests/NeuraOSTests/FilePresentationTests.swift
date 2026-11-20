import XCTest
import SwiftUI
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

    func testFailedReloadInvalidatesOnlyTheCleanTargetBuffer() {
        let content = FileContent(path: "note.txt", content: "old text", hash: "old-hash")
        let clean = OpenDocument(original: content, text: content.content)
        var documents = ["note.txt": clean, "other.txt": clean]
        FilePresentation.invalidateCleanDocument("note.txt", in: &documents)
        XCTAssertNil(documents["note.txt"], "Deleted or non-editable files must reach the fallback/unavailable view")
        XCTAssertEqual(documents["other.txt"], clean)

        // A request started with a clean buffer, then the user edited it before failure.
        documents["note.txt"] = clean
        documents["note.txt"]?.text = "edit made during reload"
        FilePresentation.invalidateCleanDocument("note.txt", in: &documents)
        XCTAssertEqual(documents["note.txt"]?.text, "edit made during reload")
        XCTAssertEqual(documents["note.txt"]?.original, content)
        XCTAssertEqual(documents["note.txt"]?.dirty, true)
    }

    /// Saves asked for while one is in flight must not overtake it: the last text asked for is the one left on disk.
    @MainActor func testSavesAreWrittenInOrderWithTheLatestText() async {
        var documents = ["note.md": OpenDocument(original: FileContent(path: "note.md", content: "v0", hash: "h0"), text: "v1")]
        let binding = Binding(get: {documents}, set: {documents = $0})
        let queue = FileSaveQueue()
        var written: [(text: String, expected: String)] = []
        let write: @MainActor (OpenDocument) async throws -> FileContent = {document in
            // The first write is slow, as a save in flight is when the tab closes.
            if written.isEmpty {try? await Task.sleep(for: .milliseconds(150))}
            written.append((document.text, document.original.hash))
            return FileContent(path: "note.md", content: document.text, hash: "hash-of-" + document.text)
        }
        queue.enqueue("note.md", documents: binding, allowed: {true}, write: write)
        await Task.yield()
        documents["note.md"]?.text = "v2"
        queue.enqueue("note.md", documents: binding, allowed: {true}, write: write)
        queue.enqueue("note.md", documents: binding, allowed: {true}, write: write)
        XCTAssertTrue(queue.saving)
        await queue.settle()
        XCTAssertEqual(written.map(\.text), ["v1", "v2"], "The third request found nothing left to write")
        XCTAssertEqual(written.map(\.expected), ["h0", "hash-of-v1"], "Each write is checked against the baseline the one before it left")
        XCTAssertEqual(documents["note.md"]?.dirty, false)
        XCTAssertEqual(documents["note.md"]?.original.content, "v2")
        XCTAssertFalse(queue.saving)

        struct Refused: LocalizedError {var errorDescription: String? {"changed on disk"}}
        documents["note.md"]?.text = "v3"
        queue.enqueue("note.md", documents: binding, allowed: {true}) {_ in throw Refused()}
        await queue.settle()
        XCTAssertEqual(queue.error, "changed on disk")
        XCTAssertEqual(documents["note.md"]?.dirty, true, "A refused write keeps the edit")
        queue.enqueue("note.md", documents: binding, allowed: {false}, write: write)
        await queue.settle()
        XCTAssertEqual(written.count, 2, "A blocked workspace is not written to")
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

    // `NSTextView.string` is a bridged NSString. Stored in the document it made
    // every dirty/equality check per keystroke walk UTF-16; the editor now hands
    // SwiftUI a native string once and compares against that cached copy.
    @MainActor func testEditorPublishesNativeTextAndComparesWithoutBridging() {
        _ = NSApplication.shared
        final class Box {var text = "初期 text\n"}
        let box = Box()
        let view = NativeTextEditor(text: Binding(get: {box.text}, set: {box.text = $0}), editable: true, diff: false)
        let coordinator = view.makeCoordinator()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.delegate = coordinator
        XCTAssertTrue(coordinator.differs(editor, from: box.text))
        editor.string = box.text; coordinator.synced = box.text
        XCTAssertFalse(editor.string.isContiguousUTF8, "fixture no longer exercises a bridged string")
        editor.insertText("追加🙂", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(box.text, "追加🙂初期 text\n")
        XCTAssertTrue(box.text.isContiguousUTF8)
        XCTAssertEqual(coordinator.synced, editor.string)
        XCTAssertFalse(coordinator.differs(editor, from: box.text))
        XCTAssertTrue(coordinator.differs(editor, from: "replaced elsewhere"))
        // A change that is not published must not leave a stale cache behind.
        coordinator.parent = NativeTextEditor(text: Binding(get: {box.text}, set: {box.text = $0}), editable: false, diff: false)
        editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(coordinator.synced)
        XCTAssertEqual(box.text, "追加🙂初期 text\n")
        XCTAssertTrue(coordinator.differs(editor, from: box.text))
        editor.string = box.text
        XCTAssertFalse(coordinator.differs(editor, from: box.text))
        XCTAssertEqual(coordinator.synced, box.text)
    }

    // Colouring used to run one text-storage editing pass per changed line. Each
    // pass invalidates layout to the end of the document, so a 10,000-line diff
    // spent seconds on the main thread. The whole diff is now one pass.
    @MainActor func testDiffColoringIsOneEditingPassForTenThousandLines() {
        let lines = (0..<10_000).map {index in
            index % 10 == 0 ? "@@ -\(index),7 +\(index),7 @@" : index % 3 == 0 ? "+追加 \(index) 🙂" : index % 3 == 1 ? "-removed \(index)" : " context \(index)"
        }
        let text = lines.joined(separator: "\n")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        _ = editor.layoutManager
        editor.string = text
        let storage = editor.textStorage!
        let counter = EditingPassCounter()
        storage.delegate = counter
        NativeTextEditor.colorDiff(storage, text: text)
        XCTAssertEqual(counter.passes, 1)
        XCTAssertEqual(lines.filter {$0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("@@")}.count, 7_000)
        var offset = 0
        for (index, line) in lines.enumerated() {
            let expected: NSColor = line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : line.hasPrefix("@@") ? .secondaryLabelColor : .labelColor
            let length = (line as NSString).length
            if index < 40 || index > 9_960 {
                var range = NSRange()
                XCTAssertEqual(storage.attribute(.foregroundColor, at: offset, effectiveRange: &range) as? NSColor, expected)
                XCTAssertEqual(storage.attribute(.foregroundColor, at: offset + length - 1, effectiveRange: nil) as? NSColor, expected)
            }
            offset += length + 1
        }
    }
}

private final class EditingPassCounter: NSObject, NSTextStorageDelegate {
    var passes = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {passes += 1}
}
