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
    func testRegistrationUsesUserDataDirectoryNotDefaultProfile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chromium = root.appendingPathComponent("Chromium")
        let defaultProfile = chromium.appendingPathComponent("Default")
        try fm.createDirectory(at: defaultProfile, withIntermediateDirectories: true)
        defer {try? fm.removeItem(at: root)}
        try OnePasswordIntegration.register(manifest: OnePasswordIntegration.manifest(), profile: chromium)
        XCTAssertTrue(fm.fileExists(atPath: chromium.appendingPathComponent("NativeMessagingHosts/" + OnePasswordIntegration.manifestName).path))
        XCTAssertFalse(fm.fileExists(atPath: defaultProfile.appendingPathComponent("NativeMessagingHosts").path))
    }
    func testRejectsManifestAndProfileSymlinksIncludingDanglingManifest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("Chromium")
        let hosts = profile.appendingPathComponent("NativeMessagingHosts")
        try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
        defer {try? fm.removeItem(at: root)}
        let outside = root.appendingPathComponent("outside.json")
        let data = try OnePasswordIntegration.manifest()
        let destination = hosts.appendingPathComponent(OnePasswordIntegration.manifestName)
        try fm.createSymbolicLink(at: destination, withDestinationURL: outside)
        XCTAssertThrowsError(try OnePasswordIntegration.register(manifest: data, profile: profile))
        XCTAssertFalse(fm.fileExists(atPath: outside.path))
        try data.write(to: outside)
        XCTAssertThrowsError(try OnePasswordIntegration.register(manifest: data, profile: profile))
        XCTAssertEqual(try Data(contentsOf: outside), data)
        try fm.removeItem(at: destination)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: profile)
        XCTAssertThrowsError(try OnePasswordIntegration.register(manifest: data, profile: alias))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
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

final class EmbeddedExtensionCatalogTests: XCTestCase {
    func testEnabledMV3ActionsAndResourceContainment() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? fm.removeItem(at: root)}
        let id = String(repeating: "a", count: 32)
        let installed = root.appendingPathComponent("Extensions/\(id)/1.0")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        func write(_ action: [String: Any], version: Int = 3) throws {
            let manifest: [String: Any] = ["manifest_version": version, "name": "Fixture", "action": action]
            try JSONSerialization.data(withJSONObject: manifest).write(to: installed.appendingPathComponent("manifest.json"))
        }
        try Data().write(to: installed.appendingPathComponent("popup.html"))
        try Data().write(to: root.appendingPathComponent("secret.html"))
        let entry: [String: Any] = ["state": 1, "path": "\(id)/1.0"]
        try write(["default_title": "Action", "default_popup": "popup.html"])
        let catalog = NCReadExtensionActions([id: entry], root.path)
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(NCReadExtensionActions([id: ["path": installed.path]], root.path).count, 1)
        XCTAssertEqual(NCReadExtensionActions([id: ["disable_reasons": [], "path": installed.path]], root.path).count, 1)
        for extra: [String: Any] in [["state": NSNull()], ["disable_reasons": [1]], ["disable_reasons": NSNull()], ["blacklist_state": 1], ["omaha_blocklist_state": 1], ["extension_telemetry_service_blocklist_state": 1]] {
            var blocked: [String: Any] = ["disable_reasons": [], "path": installed.path]
            blocked.merge(extra) {_, new in new}
            XCTAssertTrue(NCReadExtensionActions([id: blocked], root.path).isEmpty)
        }
        XCTAssertEqual(catalog.first?.title, "Action")
        XCTAssertEqual(catalog.first?.popupURL, "chrome-extension://\(id)/popup.html")
        XCTAssertTrue(NCReadExtensionActions([id: ["state": 0, "path": installed.path]], root.path).isEmpty)
        XCTAssertTrue(NCReadExtensionActions(["../bad": entry], root.path).isEmpty)
        try write(["default_popup": "popup.html?mode=toolbar#action"])
        XCTAssertEqual(NCReadExtensionActions([id: entry], root.path).first?.popupURL, "chrome-extension://\(id)/popup.html?mode=toolbar#action")
        for popup in ["../escape.html", "https://example.com/popup", "//example.com/popup", "/absolute.html"] {
            try write(["default_popup": popup])
            XCTAssertNil(NCReadExtensionActions([id: entry], root.path).first?.popupURL, popup)
        }
        try fm.createSymbolicLink(at: installed.appendingPathComponent("outside"), withDestinationURL: root)
        try write(["default_popup": "outside/secret.html"])
        XCTAssertNil(NCReadExtensionActions([id: entry], root.path).first?.popupURL)
        try write(["default_popup": "popup.html"], version: 2)
        XCTAssertTrue(NCReadExtensionActions([id: entry], root.path).isEmpty)
    }
    func testLocalizationUnpackedPathAndMissingPopup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? fm.removeItem(at: root)}
        try fm.createDirectory(at: root.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"__MSG_name__","default_locale":"en","action":{}}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data(#"{"name":{"message":"Localized fixture"}}"#.utf8).write(to: root.appendingPathComponent("_locales/en/messages.json"))
        let catalog = NCReadExtensionActions([String(repeating: "b", count: 32): ["state": 1, "path": root.path]], root.path)
        XCTAssertEqual(catalog.first?.title, "Localized fixture")
        XCTAssertNil(catalog.first?.popupURL)
        try Data(#"{"manifest_version":3,"name":"__MSG__","action":{}}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(NCReadExtensionActions([String(repeating: "b", count: 32): ["path": root.path]], root.path).first?.title, "__MSG__")
        XCTAssertTrue(NCReadExtensionActions(["bad": NSNull()], root.path).isEmpty)
    }
}
