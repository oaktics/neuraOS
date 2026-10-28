import XCTest
@testable import NeuraOS

final class BrowserMigrationTests: XCTestCase {
    @MainActor func testLegacyAddressMigratesOnceAndSurvivesReopening() {
        let suite = "browser-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {defaults.removePersistentDomain(forName: suite)}
        defaults.set("https://example.com/project", forKey: "browser.workspace")
        defaults.set("https://example.com/existing", forKey: "browser.workspace.existing")
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "workspace.existing", workspaceId: "workspace", defaults: defaults), "https://example.com/existing")
        XCTAssertNotNil(defaults.string(forKey: "browser.workspace"))
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "workspace.first", workspaceId: "workspace", defaults: defaults), "https://example.com/project")
        XCTAssertNil(defaults.string(forKey: "browser.workspace"))
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "workspace.first", workspaceId: "workspace", defaults: defaults), "https://example.com/project")
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "workspace.second", workspaceId: "workspace", defaults: defaults), "https://www.google.com/")
        defaults.set("https://example.com/other", forKey: "browser.other")
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "other.first", workspaceId: "other", defaults: defaults), "https://example.com/other")
    }
}
