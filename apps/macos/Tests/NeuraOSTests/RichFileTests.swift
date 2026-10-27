import XCTest
import AppKit
import PDFKit
@testable import NeuraOS

final class RichFileTests: XCTestCase {
    func testNativePreviewRoutingAndCodeLanguages() {
        XCTAssertEqual(PreviewKind.detect("scan.PDF"), .pdf)
        XCTAssertEqual(PreviewKind.detect("photo.png"), .image)
        XCTAssertEqual(PreviewKind.detect("recording.mp3"), .media)
        XCTAssertEqual(PreviewKind.detect("movie.mp4"), .media)
        XCTAssertEqual(PreviewKind.detect("report.docx"), .quickLook)
        XCTAssertEqual(CodePresentation.language("app.TSX"), "typescript")
        XCTAssertEqual(CodePresentation.language("Dockerfile"), "dockerfile")
        XCTAssertNil(CodePresentation.language("notes.txt"))
    }

    func testCreateCopyMoveAndCollisionProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {try? FileManager.default.removeItem(at: root)}
        _ = try ExplorerFiles.perform(.newFolder, root: root.path, source: "", destination: "docs")
        _ = try ExplorerFiles.perform(.newFile, root: root.path, source: "", destination: "docs/a.txt")
        try Data("keep me".utf8).write(to: root.appendingPathComponent("docs/a.txt"))
        _ = try ExplorerFiles.perform(.duplicate, root: root.path, source: "docs/a.txt", destination: "docs/b.txt")
        XCTAssertThrowsError(try ExplorerFiles.perform(.newFile, root: root.path, source: "", destination: "docs/a.txt"))
        XCTAssertThrowsError(try ExplorerFiles.perform(.move, root: root.path, source: "docs/b.txt", destination: "docs/a.txt"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("docs/a.txt"), encoding: .utf8), "keep me")
        let change = try ExplorerFiles.perform(.rename, root: root.path, source: "docs", destination: "notes")
        XCTAssertEqual(ExplorerFiles.remap("docs/a.txt", change: change), "notes/a.txt")
        XCTAssertEqual(ExplorerFiles.remap("docs-other/a.txt", change: change), "docs-other/a.txt")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes/b.txt"), encoding: .utf8), "keep me")
        XCTAssertThrowsError(try ExplorerFiles.perform(.move, root: root.path, source: "notes", destination: "notes/nested"))
    }

    func testMutationRejectsTraversalGitAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {try? FileManager.default.removeItem(at: root)}
        for path in ["", "/tmp/escape", "../escape", "a/../escape", ".git/config", "a//b", "./file", "bad\0name"] {
            XCTAssertThrowsError(try ExplorerFiles.target(root: root.path, path: path, mustExist: false), path)
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try ExplorerFiles.target(root: root.path, path: "link/file", mustExist: false))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: root.appendingPathComponent("missing").path)
        XCTAssertThrowsError(try ExplorerFiles.target(root: root.path, path: "dangling", mustExist: false))
        XCTAssertNil(ExplorerFiles.remap("docs/a.txt", change: ExplorerChange(oldPath: "docs", newPath: nil)))
    }

    func testGitCaseAliasesCannotCreateOrMoveIntoMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("nested/.git"), withIntermediateDirectories: true)
        defer {try? fm.removeItem(at: root)}
        let source = root.appendingPathComponent("note.txt")
        try Data("keep me".utf8).write(to: source)
        for alias in [".git", ".GIT", ".Git", ".gIt"] {
            XCTAssertThrowsError(try ExplorerFiles.perform(.newFile, root: root.path, source: "", destination: alias + "/index.lock"))
            XCTAssertThrowsError(try ExplorerFiles.perform(.move, root: root.path, source: "note.txt", destination: alias + "/index.lock"))
            XCTAssertThrowsError(try ExplorerFiles.target(root: root.path, path: "nested/" + alias + "/config", mustExist: false))
        }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep me")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    func testLineNumbersCountLFAndCRLFIncludingScrolledPrefixes() {
        for ending in ["\n", "\r\n"] {
            let lines = ["日本語😀", "second", "third"]
            let text = (lines.joined(separator: ending) + ending) as NSString
            var offset = 0
            var lineNumber = 1
            for (index, line) in lines.enumerated() {
                // Match both calculations in the ruler: initial visible prefix and each fragment.
                XCTAssertEqual(CodePresentation.lineFeedCount(text.substring(to: offset)) + 1, index + 1)
                XCTAssertEqual(lineNumber, index + 1)
                let fragment = NSRange(location: offset, length: ((line + ending) as NSString).length)
                lineNumber += CodePresentation.lineFeedCount(text.substring(with: fragment))
                offset += fragment.length
            }
            XCTAssertEqual(lineNumber, 4)
        }
        XCTAssertEqual(CodePresentation.lineFeedCount("first\r\nsecond\nthird\r\n"), 3)
        XCTAssertEqual(CodePresentation.lineFeedCount(""), 0)
    }

    @MainActor func testPDFLoadsAndNavigates() throws {
        _ = NSApplication.shared
        let document = PDFDocument()
        for _ in 0..<3 {
            let image = NSImage(size: NSSize(width: 200, height: 300))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 200, height: 300).fill(); image.unlockFocus()
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer {try? FileManager.default.removeItem(at: url)}
        XCTAssertTrue(document.write(to: url))
        let model = PDFPreviewModel()
        model.load(url)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.pages, 3)
        model.go(2)
        XCTAssertEqual(model.view.currentPage, model.view.document?.page(at: 1))
        model.go(100)
        XCTAssertEqual(model.view.currentPage, model.view.document?.page(at: 1))
        model.search("")
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.matches.isEmpty)
    }

    @MainActor func testPDFSearchFindsAndCyclesTextMatches() async throws {
        _ = NSApplication.shared
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        editor.string = "needle first\nsecond needle"
        editor.font = .systemFont(ofSize: 14)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try editor.dataWithPDF(inside: editor.bounds).write(to: url)
        defer {try? FileManager.default.removeItem(at: url)}
        let model = PDFPreviewModel()
        model.load(url)
        let finished = expectation(forNotification: .PDFDocumentDidEndFind, object: model.view.document)
        model.search("needle")
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(model.matches.count, 2)
        model.showMatch(1)
        XCTAssertEqual(model.matchIndex, 1)
        model.showMatch(2)
        XCTAssertEqual(model.matchIndex, 0)
        model.search("")
        XCTAssertTrue(model.matches.isEmpty)
        XCTAssertNil(model.view.currentSelection)
    }

    func testHighlighterPreservesSourceAndProducesColors() async throws {
        let source = "let greeting = \"日本語\"\n// comment\n"
        let highlighted = await CodeHighlighter.shared.highlight(source, language: "swift", dark: false)
        let result = try XCTUnwrap(highlighted)
        XCTAssertEqual(result.string, source)
        var colors = Set<String>()
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) {value, _, _ in
            if let color = value as? NSColor {colors.insert(color.description)}
        }
        XCTAssertGreaterThan(colors.count, 1)
    }
}
