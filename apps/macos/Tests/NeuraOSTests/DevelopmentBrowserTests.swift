import XCTest
@testable import NeuraOS

final class DevelopmentBrowserTests: XCTestCase {
    func testExternalHandoffExcludesOldNeuraOSDefaultAndOtherCopies() {
        let own = URL(fileURLWithPath: "/test/neuraOS.app")
        let otherCopy = URL(fileURLWithPath: "/test/old/neuraOS.app")
        let safari = URL(fileURLWithPath: "/test/Safari.app")
        let chrome = URL(fileURLWithPath: "/test/Chrome.app")
        let unknown = URL(fileURLWithPath: "/test/unknown.app")
        let identifiers = [own: "app.neuraos.native", otherCopy: "app.neuraos.native",
                           safari: "com.apple.Safari", chrome: "com.google.Chrome"]
        func select(_ current: URL?, _ candidates: [URL]) -> URL? {
            DefaultBrowser.outsideApplication(defaultApplication: current, candidates: candidates,
                                              ownIdentifier: "app.neuraos.native", identifier: {identifiers[$0]})
        }
        XCTAssertEqual(select(own, [otherCopy, unknown, chrome, safari]), safari)
        XCTAssertEqual(select(chrome, [safari]), chrome)
        XCTAssertEqual(select(own, [otherCopy, chrome]), chrome)
        XCTAssertNil(select(own, [otherCopy, unknown]))
    }

    @MainActor func testNewTabIsBlankAndSavedDestinationSurvives() throws {
        let suite = "development-browser-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "w.new", workspaceId: "w", defaults: defaults), "about:blank")
        defaults.set("http://localhost:3000/", forKey: "browser.w.saved")
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "w.saved", workspaceId: "w", defaults: defaults), "http://localhost:3000/")
    }
}
