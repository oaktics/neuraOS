import XCTest
import ChromiumBridge
@testable import NeuraOS

final class BrowserConsoleTests: XCTestCase {
    @MainActor func testRetentionOrderFilterAndConsumeOnlyReturned() {
        let buffer = NCConsoleBuffer()
        for i in 0..<502 {buffer.appendLevel(i % 2 == 0 ? "info" : "error", text: "message \(i)", sourceURL: "https://example.test/\(i)", line: i + 1)}
        let result = buffer.readLevel("error", limit: 2, clear: true)
        let entries = result["entries"] as! [[String: Any]]
        XCTAssertEqual(entries.map {$0["text"] as! String}, ["message 3", "message 5"])
        XCTAssertEqual(entries[0]["line"] as? Int, 4)
        XCTAssertNotNil(entries[0]["timestamp"] as? Double)
        XCTAssertEqual(result["dropped"] as? Int, 2)
        XCTAssertEqual(result["hasMore"] as? Bool, true)
        let remaining = buffer.readLevel(nil, limit: 500, clear: false)["entries"] as! [[String: Any]]
        XCTAssertEqual(remaining.count, 498)
        XCTAssertEqual(remaining.first?["text"] as? String, "message 2")
        XCTAssertFalse(remaining.contains {$0["text"] as? String == "message 3"})
        XCTAssertTrue((NCConsoleBuffer().readLevel(nil, limit: 100, clear: false)["entries"] as! [Any]).isEmpty)
    }

    @MainActor func testEscapedUnicodeTextAndResponseSizeAreBounded() throws {
        let buffer = NCConsoleBuffer()
        let text = String(repeating: "\u{0001}", count: 8191) + "😀tail"
        for _ in 0..<500 {buffer.appendLevel("error", text: text, sourceURL: String(repeating: "😀", count: 3000), line: 0)}
        let result = buffer.readLevel(nil, limit: 500, clear: true)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: result).count, 256 * 1024)
        let entries = result["entries"] as! [[String: Any]]
        XCTAssertGreaterThan(entries.count, 0)
        XCTAssertLessThan(entries.count, 500)
        XCTAssertEqual((entries[0]["text"] as! String).utf16.count, 8191)
        XCTAssertEqual((entries[0]["url"] as! String).utf16.count, 2048)
        XCTAssertNil(entries[0]["line"])
        XCTAssertEqual(result["hasMore"] as? Bool, true)
        XCTAssertFalse((buffer.readLevel(nil, limit: 1, clear: false)["entries"] as! [Any]).isEmpty)
    }

    @MainActor func testExecuteUsesHistoryWithoutDevToolsAndHonorsPermission() async throws {
        let view = NCChromiumView(frame: .zero)
        view.consoleBuffer.appendLevel("error", text: "before request", sourceURL: "https://example.test", line: 1)
        let deadline = Date().timeIntervalSince1970 * 1000 + 1000
        do {
            _ = try await BrowserAutomation.execute(["action":"console", "clear":true], view:view, deadline:deadline, allowed:{false})
            XCTFail("disabled tab must reject reads and clear")
        } catch {XCTAssertEqual((error as? BrowserAutomationError)?.code, "browser_disabled")}
        let result = try await BrowserAutomation.execute(["action":"console"], view:view, deadline:deadline)
        XCTAssertEqual((result["entries"] as! [[String:Any]]).first?["text"] as? String, "before request")
        XCTAssertEqual(result["untrusted"] as? Bool, true)
    }
}
