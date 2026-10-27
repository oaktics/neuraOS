import XCTest
import ServiceManagement
@testable import NeuraOS

final class SleepServiceRegistrationTests: XCTestCase {
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
