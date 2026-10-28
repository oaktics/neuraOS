import XCTest
import ChromiumBridge
@testable import NeuraOS

final class BrowserDownloadIsolationTests: XCTestCase {
    func testTerminalCallbackOrderingCannotReopenPanelOrReviveDownload() {
        XCTAssertTrue(NCVerifyDownloadTerminalStates())
    }

    func testMockKeychainRequiresProcessLocalSmokeProfile() {
        let defaults = UserDefaults.standard
        let domain = "NeuraChromiumSmoke"
        let original = defaults.volatileDomain(forName: domain)
        defer { defaults.setVolatileDomain(original, forName: domain) }
        defaults.removeVolatileDomain(forName: domain)
        XCTAssertFalse(NCChromiumUsesTestKeychain(), "Normal startup must use the real Keychain")
        defaults.setVolatileDomain(["NeuraChromiumSmokeData": ""], forName: domain)
        XCTAssertFalse(NCChromiumUsesTestKeychain())
        defaults.setVolatileDomain(["NeuraChromiumSmokeData": 42], forName: domain)
        XCTAssertFalse(NCChromiumUsesTestKeychain())
        defaults.setVolatileDomain(["NeuraChromiumSmokeData": "/tmp/disposable-download-fixture"], forName: domain)
        XCTAssertTrue(NCChromiumUsesTestKeychain())
        defaults.removeVolatileDomain(forName: domain)
        XCTAssertFalse(NCChromiumUsesTestKeychain())
    }
    func testDownloadSnapshotsPreserveEarlierProgressForViewDiffing() {
        let download = NCDownload()
        for (key, value) in ["name": "fixture.bin", "path": "/tmp/fixture.bin", "status": "running", "detail": "ダウンロード中"] {
            download.setValue(value, forKey: key)
        }
        download.setValue(100, forKey: "total")
        let initial = DownloadSnapshot(download)
        download.setValue(75, forKey: "received")
        let progress = DownloadSnapshot(download)
        download.setValue("complete", forKey: "status")
        let complete = DownloadSnapshot(download)
        XCTAssertEqual(initial.received, 0)
        XCTAssertEqual(progress.received, 75)
        XCTAssertEqual(progress.status, "running")
        XCTAssertEqual(complete.status, "complete")
    }

}
