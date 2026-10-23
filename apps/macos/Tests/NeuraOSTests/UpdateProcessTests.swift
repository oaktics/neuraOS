import XCTest
@testable import NeuraOS

final class UpdateProcessTests: XCTestCase {
    func testPreparationCanOwnItsDeadline() throws {
        let data = try UpdateProcess.run(executable: "/bin/sleep", arguments: ["0.15"], timeout: nil)
        XCTAssertTrue(data.isEmpty)
    }

    func testLargeOutputDoesNotBlockProcessExit() throws {
        let data = try UpdateProcess.run(executable: "/bin/sh", arguments: ["-c", "yes update | head -c 200000"], timeout: 5)
        XCTAssertEqual(data.count, 200000)
    }

    func testNonzeroExitIncludesDiagnostic() {
        XCTAssertThrowsError(try UpdateProcess.run(executable: "/bin/sh", arguments: ["-c", "echo verification-failed >&2; exit 1"], timeout: 5)) {error in
            XCTAssertTrue(error.localizedDescription.contains("verification-failed"))
        }
    }

    func testUnresponsiveProcessHasBoundedDeadline() {
        let started = ContinuousClock.now
        XCTAssertThrowsError(try UpdateProcess.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)) {error in
            XCTAssertEqual((error as NSError).code, 2)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(4))
    }
}
