import XCTest
import ChromiumBridge

final class BrowserCloseReasonTests: XCTestCase {
    func testCloseWinsOverDetachAndRendererTermination() {
        XCTAssertEqual(NCChromiumInvalidationReason(true, false), "browser_tab_closed")
        XCTAssertEqual(NCChromiumInvalidationReason(false, true), "browser_tab_closed", "window.close precedes do_close")
        XCTAssertEqual(NCChromiumInvalidationReason(true, true), "browser_tab_closed")
        XCTAssertEqual(NCChromiumInvalidationReason(false, false), "browser_renderer_crashed")
    }
}
