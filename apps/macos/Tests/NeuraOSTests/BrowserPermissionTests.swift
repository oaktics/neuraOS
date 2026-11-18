import XCTest
import ChromiumBridge
@testable import NeuraOS

final class BrowserPermissionTests: XCTestCase {
    @MainActor private final class ProbeView: NCChromiumView {
        var cancellations = 0
        override func cancelDevTools() {cancellations += 1}
    }

    @MainActor func testCancellationPreservesPermissionButExplicitDisconnectPersists() {
        let key = "permission-test.\(UUID().uuidString)"
        let preference = "browser.mcpDisabled." + key
        defer {UserDefaults.standard.removeObject(forKey: preference)}
        let view = ProbeView(frame: .zero)
        // No CEF initialization or daemon connection is needed to exercise cancellation.
        let model = BrowserModel(storageId: key, workspaceId: "permission-test", projectId: "test", view: view, automation: false)
        model.automationEnabled = true
        let automation = BrowserAutomation()
        for reason in ["browser_cancelled", "browser_renderer_crashed", "browser_tab_closed"] {
            automation.cancel(model, reason: reason)
            XCTAssertTrue(model.automationEnabled, reason)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: preference), reason)
        }
        XCTAssertEqual(view.cancellations, 3)
        automation.stop(model)
        XCTAssertFalse(model.automationEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: preference))
        automation.cancel(model)
        XCTAssertFalse(model.automationEnabled, "Cancellation must not re-enable a user-disabled tab")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: preference))
        XCTAssertEqual(view.cancellations, 5)
    }

    @MainActor func testNativeInvalidationDoesNotPersistAnImplicitOptOut() async {
        let key = "permission-test.\(UUID().uuidString)"
        let preference = "browser.mcpDisabled." + key
        defer {UserDefaults.standard.removeObject(forKey: preference)}
        let view = ProbeView(frame: .zero)
        let model = BrowserModel(storageId: key, workspaceId: "permission-test", projectId: "test", view: view, automation: false)
        model.automationEnabled = true
        view.onAutomationInvalidated?("browser_renderer_crashed")
        // The bridge schedules its model callback on the main queue.
        await withCheckedContinuation {continuation in DispatchQueue.main.async {continuation.resume()}}
        XCTAssertEqual(view.cancellations, 1)
        XCTAssertTrue(model.automationEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: preference))
    }
}
