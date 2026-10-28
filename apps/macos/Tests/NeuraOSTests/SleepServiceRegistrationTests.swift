import XCTest
import ServiceManagement
@testable import NeuraOS

final class SleepServiceRegistrationTests: XCTestCase {
    @MainActor func testRepairWaitsForRemovalBeforeRegistering() async throws {
        var events: [String] = []
        try await SleepServiceRegistration.repair(status: {.enabled}, validate: {
            events.append("validate")
        }, unregister: {
            await Task.yield()
            events.append("unregister")
        }, register: {events.append("register")})
        XCTAssertEqual(events, ["validate", "unregister", "register"])
    }

    @MainActor func testRepairPreservesPendingApproval() async throws {
        try await SleepServiceRegistration.repair(status: {.requiresApproval}, validate: {},
            unregister: {XCTFail("Must preserve pending approval")},
            register: {XCTFail("Must preserve pending approval")})
    }

    @MainActor func testRepairMissingRegistrationDoesNotUnregister() async throws {
        for state in [SMAppService.Status.notFound, .notRegistered] {
            var registered = false
            try await SleepServiceRegistration.repair(status: {state}, validate: {},
                unregister: {XCTFail("No registration to remove")},
                register: {registered = true})
            XCTAssertTrue(registered)
        }
    }

    @MainActor func testRepairValidatesBeforeRemovingRegistration() async {
        do {
            try await SleepServiceRegistration.repair(status: {.enabled},
                validate: {throw NSError(domain: "Bundle", code: 1)},
                unregister: {XCTFail("Preserve registration for an invalid bundle")},
                register: {XCTFail("Invalid bundle")})
            XCTFail("Expected validation error")
        } catch {XCTAssertEqual((error as NSError).domain, "Bundle")}
    }

    @MainActor func testRepairDoesNotRegisterAfterRemovalFailure() async {
        do {
            try await SleepServiceRegistration.repair(status: {.enabled}, validate: {},
                unregister: {throw NSError(domain: "Removal", code: 1)},
                register: {XCTFail("Must wait for successful removal")})
            XCTFail("Expected removal error")
        } catch {XCTAssertEqual((error as NSError).domain, "Removal")}
    }

    func testMissingRecordAndFirstInstallRegisterThenRequestApproval() throws {
        for initial in [SMAppService.Status.notFound, .notRegistered] {
            var state = initial
            var events: [String] = []
            let result = try SleepServiceRegistration.prepare(status: {state}, validate: {
                events.append("validate")
            }, register: {
                events.append("register")
                state = .requiresApproval
            })
            XCTAssertEqual(result, .requiresApproval)
            XCTAssertEqual(events, ["validate", "register"])
        }
    }

    func testApprovedAndPendingServicesAreNotReregistered() throws {
        for state in [SMAppService.Status.enabled, .requiresApproval] {
            let result = try SleepServiceRegistration.prepare(status: {state}, validate: {
                XCTFail("Existing registrations should be preserved")
            }, register: {XCTFail("Must not repeat registration or approval")})
            XCTAssertEqual(result, state)
        }
    }

    func testIncompleteBundleNeverRegisters() {
        XCTAssertThrowsError(try SleepServiceRegistration.prepare(status: {.notFound}, validate: {
            try SleepServiceRegistration.validateBundle(at: URL(fileURLWithPath: "/nonexistent-neura-app"))
        }, register: {XCTFail("Missing helper must not register")}))
    }

    func testRegistrationFailureRetainsSystemError() {
        let failure = NSError(domain: "ServiceManagementTest", code: 42)
        XCTAssertThrowsError(try SleepServiceRegistration.prepare(status: {.notFound}, validate: {}, register: {
            throw failure
        })) {error in
            XCTAssertEqual(error as NSError, failure)
        }
    }

    func testRegistrationMayEnableImmediatelyOrRemainUnresolved() throws {
        for after in [SMAppService.Status.enabled, .notFound] {
            var state = SMAppService.Status.notRegistered
            let result = try SleepServiceRegistration.prepare(status: {state}, validate: {}, register: {state = after})
            XCTAssertEqual(result, after)
        }
    }
}
