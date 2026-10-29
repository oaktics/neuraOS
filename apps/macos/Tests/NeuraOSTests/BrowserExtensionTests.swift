import XCTest
import ChromiumBridge
@testable import NeuraOS

final class BrowserExtensionTests: XCTestCase {
    @MainActor func testExtensionWindowRejectsPrivilegedAndMalformedURLsBeforeInitializingCEF() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "chrome://settings/", "chrome://extensions/?id=untrusted", "https://user:pass@example.com", "https://", "custom://example"] {
            XCTAssertNotNil(NCOpenExtensionWindow(url), url)
        }
    }
    @MainActor func testExtensionSmokeCannotRunFromTheProductionOrTestRunnerBundle() {
        XCTAssertEqual(NCRunExtensionsSmoke("http://127.0.0.1/", "/tmp/not-used", 44331, nil), 2)
        XCTAssertFalse(NCChromiumUsesTestKeychain())
    }
}

final class OnePasswordRegistrationTests: XCTestCase {
    func testOfficialManifestAndIdempotentProfileRegistration() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: profile)}
        let data = try OnePasswordIntegration.manifest()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        XCTAssertEqual(json["name"] as? String, "com.1password.1password")
        XCTAssertEqual(json["allowed_origins"] as? [String], ["chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/"])
        try OnePasswordIntegration.register(manifest: data, profile: profile)
        try OnePasswordIntegration.register(manifest: data, profile: profile)
        let file = profile.appendingPathComponent("NativeMessagingHosts/" + OnePasswordIntegration.manifestName)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertThrowsError(try OnePasswordIntegration.register(manifest: Data("different".utf8), profile: profile))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testDoesNotFollowHostDirectorySymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("profile"), outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {try? fm.removeItem(at: root)}
        try fm.createSymbolicLink(at: profile.appendingPathComponent("NativeMessagingHosts"), withDestinationURL: outside)
        XCTAssertThrowsError(try OnePasswordIntegration.register(manifest: OnePasswordIntegration.manifest(), profile: profile))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
    }
}
