import AppKit
import SwiftUI
import XCTest
import MarkdownEngine
@testable import NeuraOS

final class MarkdownRichEditorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes/sub"), withIntermediateDirectories: true)
        for file in ["notes/today.md", "notes/sub/deep.md", "notes/pic.png", "README.md"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDown() {try? FileManager.default.removeItem(at: root)}

    func testModeFallsBackToRichForUnknownStoredValues() {
        XCTAssertEqual(MarkdownMode.stored("source"), .source)
        XCTAssertEqual(MarkdownMode.stored("live"), .rich)
        XCTAssertEqual(MarkdownMode.stored(""), .rich)
    }

    func testRelativePathsStayInsideTheWorkspace() {
        XCTAssertEqual(MarkdownLinks.join("notes", "../README.md"), "README.md")
        XCTAssertNil(MarkdownLinks.join("notes", "../../outside.md"))
        XCTAssertEqual(MarkdownLinks.relative("./pic.png", from: "notes/today.md", root: root.path), "notes/pic.png")
        XCTAssertEqual(MarkdownLinks.relative("sub/deep.md#part", from: "notes/today.md", root: root.path), "notes/sub/deep.md")
        XCTAssertEqual(MarkdownLinks.relative("/README.md", from: "notes/today.md", root: root.path), "README.md")
        XCTAssertNil(MarkdownLinks.relative("missing.png", from: "notes/today.md", root: root.path))
        XCTAssertNil(MarkdownLinks.relative("https://example.com/a.png", from: "notes/today.md", root: root.path))
        XCTAssertNil(MarkdownLinks.relative("../../etc/passwd", from: "notes/today.md", root: root.path))
    }

    func testWikiLinksResolveBesideTheNoteThenAnywhereThenOfferCreation() {
        XCTAssertEqual(MarkdownLinks.resolveWiki("today", from: "notes/sub/deep.md", root: root.path), .file("notes/today.md"))
        XCTAssertEqual(MarkdownLinks.resolveWiki("deep", from: "README.md", root: root.path), .file("notes/sub/deep.md"))
        XCTAssertEqual(MarkdownLinks.resolveWiki("README#intro", from: "notes/today.md", root: root.path), .file("README.md"))
        XCTAssertEqual(MarkdownLinks.resolveWiki("新しいメモ", from: "notes/today.md", root: root.path), .create("notes/新しいメモ.md"))
        XCTAssertEqual(MarkdownLinks.resolveWiki("../escape", from: "notes/today.md", root: root.path), .none)
        XCTAssertEqual(MarkdownLinks.resolveWiki("  ", from: "notes/today.md", root: root.path), .none)
    }

    func testPastedImagesAreSavedBesideTheNoteWithoutOverwriting() throws {
        let now = Date(timeIntervalSince1970: 0)
        let first = try MarkdownLinks.saveImage(Data("a".utf8), named: "image.png", beside: "notes/today.md", root: root.path, now: now)
        let second = try MarkdownLinks.saveImage(Data("b".utf8), named: "image.png", beside: "notes/today.md", root: root.path, now: now)
        XCTAssertTrue(first.hasPrefix("image-") && first.hasSuffix(".png"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes/" + first)), Data("a".utf8))
        XCTAssertEqual(try MarkdownLinks.saveImage(Data("c".utf8), named: "pic.png", beside: "notes/today.md", root: root.path), "pic-2.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes/pic.png")), Data("x".utf8))
        XCTAssertEqual(try MarkdownLinks.saveImage(Data("d".utf8), named: "my shot.PNG", beside: "README.md", root: root.path), "my%20shot.png")
        XCTAssertThrowsError(try MarkdownLinks.saveImage(Data("e".utf8), named: "script.sh", beside: "README.md", root: root.path))
    }

    func testImageProviderOnlyReadsWorkspaceImages() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2)); image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("notes/pic.png"))
        let provider = WorkspaceImageProvider(root: root.path, path: "notes/today.md")
        XCTAssertNotNil(provider.image(for: EmbeddedImageRequest(name: "pic.png")))
        XCTAssertNotNil(provider.image(for: EmbeddedImageRequest(name: "./pic.png")))
        XCTAssertNil(provider.image(for: EmbeddedImageRequest(name: "https://example.com/pic.png")))
        XCTAssertNil(provider.image(for: EmbeddedImageRequest(name: "today.md")))
        XCTAssertNil(provider.image(for: EmbeddedImageRequest(name: "../../pic.png")))
    }

    func testLinesReturnToBodyTextAndToggleAsCheckItems() {
        XCTAssertEqual(MarkdownLineEdit.restyle("## 見出し", to: .body), "見出し")
        XCTAssertEqual(MarkdownLineEdit.restyle("  - [x] done\n> quote\n3. third", to: .body), "done\nquote\nthird")
        XCTAssertEqual(MarkdownLineEdit.restyle("plain #tag", to: .body), "plain #tag")
        XCTAssertEqual(MarkdownLineEdit.restyle("買い物", to: .checklist), "- [ ] 買い物")
        XCTAssertEqual(MarkdownLineEdit.restyle("", to: .checklist), "- [ ] ")
        XCTAssertEqual(MarkdownLineEdit.restyle("# a\n\n  * b\n1. c", to: .checklist), "- [ ] a\n\n  - [ ] b\n- [ ] c")
        XCTAssertEqual(MarkdownLineEdit.restyle("- [ ] a\n  - [x] b", to: .checklist), "a\n  b")
        XCTAssertEqual(MarkdownLineEdit.restyle("- [ ] a\nb", to: .checklist), "- [ ] a\n- [ ] b")
    }

    func testLinksUseTheSelectionAsTheirLabel() {
        XCTAssertEqual(MarkdownLineEdit.link(label: "資料", url: " https://example.com/a b "), "[資料](https://example.com/a%20b)")
        XCTAssertEqual(MarkdownLineEdit.link(label: "", url: "https://example.com"), "[https://example.com](https://example.com)")
        XCTAssertEqual(MarkdownLineEdit.link(label: "a]b", url: "https://example.com/(x)"), "[a\\]b](https://example.com/%28x%29)")
    }

    /// The toolbar's own commands type into the engine's text view, found from the editor's anchor.
    @MainActor func testToolbarCommandsEditTheDocumentThroughTheTextView() {
        _ = NSApplication.shared
        var text = "# 見出し\n買い物\nリンク先"
        let session = MarkdownEditorSession(root: root.path, path: "notes/today.md")
        let view = NativeTextViewWrapper(text: Binding(get: {text}, set: {text = $0}), configuration: session.configuration)
            .background(MarkdownEditorAnchor(session: session)).frame(width: 600, height: 400)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        func editor(_ view: NSView) -> NSTextView? {(view as? NSTextView) ?? view.subviews.lazy.compactMap(editor).first}
        guard let editor = editor(host) else {return XCTFail("no text view")}

        editor.setSelectedRange(NSRange(location: 2, length: 0))
        session.restyleLines(.body)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(text, "見出し\n買い物\nリンク先")

        editor.setSelectedRange(NSRange(location: 4, length: 3))
        session.restyleLines(.checklist)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(text, "見出し\n- [ ] 買い物\nリンク先")

        let label = (text as NSString).range(of: "リンク先")
        editor.setSelectedRange(label)
        XCTAssertEqual(session.selectedText, "リンク先")
        session.insertLink("https://example.com")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(text, "見出し\n- [ ] 買い物\n[リンク先](https://example.com)")

        // The engine keeps one undo stack per document and vends it through the text view's delegate.
        editor.delegate?.undoManager?(for: editor)?.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(editor.string, "見出し\n- [ ] 買い物\nリンク先", "Toolbar edits are undoable")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(text, editor.string, "What is undone must also leave the document that gets saved")
        editor.delegate?.undoManager?(for: editor)?.redo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(text, "見出し\n- [ ] 買い物\n[リンク先](https://example.com)")
        window.close()
    }

    /// The rich editor only styles the text: opening a file must leave every byte as it was.
    @MainActor func testShowingADocumentDoesNotRewriteIt() {
        _ = NSApplication.shared
        let sample = "---\ntitle: x\n---\n\n# Title\n\n* star bullet\n+ plus bullet\n\n__bold__ _em_ [[Note|alias]]\n\n| a | b |\n|:-|-:|\n| 1 | 2 |\n\n<details><summary>s</summary>\n\nbody\n\n</details>\n\n```swift\nlet x = 1\n```\n"
        var text = sample
        let session = MarkdownEditorSession(root: root.path, path: "notes/today.md")
        let view = NativeTextViewWrapper(text: Binding(get: {text}, set: {text = $0}), configuration: session.configuration)
            .frame(width: 600, height: 400)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        window.close()
        XCTAssertEqual(text, sample)
    }
}
