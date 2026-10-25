import XCTest
@testable import NeuraOS

final class DiagnosticsTests: XCTestCase {
    func testHeartbeatDetectsOnceAndDoesNotQueueRepeatedProbes() {
        var monitor = UIHeartbeat()
        XCTAssertTrue(monitor.tick(at: 0).probe)
        XCTAssertFalse(monitor.tick(at: 1).probe)
        XCTAssertEqual(monitor.tick(at: 5).hang, 5)
        XCTAssertNil(monitor.tick(at: 60).hang)
        XCTAssertFalse(monitor.tick(at: 61).probe)
        XCTAssertEqual(monitor.acknowledge(at: 62), 62)
        XCTAssertTrue(monitor.tick(at: 63).probe)
        XCTAssertNil(monitor.acknowledge(at: 64))
    }
    @MainActor func testBusyActionsAreIsolatedAndCannotReleaseAnotherAction() {
        let model = AppModel(startPolling: false)
        XCTAssertTrue(model.beginAction("workspace-a", label: "Updating"))
        XCTAssertFalse(model.beginAction("workspace-a", label: "Deleting"))
        XCTAssertTrue(model.beginAction("workspace-b", label: "Opening"))
        model.endAction("workspace-b")
        XCTAssertTrue(model.isBusy("workspace-a"))
        XCTAssertFalse(model.isBusy("workspace-b"))
        XCTAssertEqual(model.pendingActions["workspace-a"], "Updating")
        model.endAction("workspace-a")
        XCTAssertTrue(model.pendingActions.isEmpty)
    }
    @MainActor func testFailedActionReleasesOnlyItsOwnBusyState() async {
        let model = AppModel(startPolling: false)
        model.beginAction("other-workspace", label: "Other work")
        await model.createWorkspace(projectId: "project", base: nil)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isBusy("project.create.project"))
        XCTAssertTrue(model.isBusy("other-workspace"))
    }
    func testRotationExportAndPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: directory)}
        let log = Diagnostics(directory: directory, limit: 1)
        log.record("operation.start", operation: "file.save", id: "test")
        log.flush()
        log.record("operation.success", operation: "file.save", id: "test", duration: 1)
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("app.previous.jsonl").path))
        let report = directory.appendingPathComponent("report.json")
        try await log.export(to: report)
        let data = try Data(contentsOf: report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(object["logs"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: report.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testCrashReportExportsOnlyMetadataAndSymbolicationOffsets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: directory)}
        let uuid = UUID().uuidString
        let header: [String: Any] = ["incident_id": uuid, "timestamp": "2026-10-26", "app_name": "neuraOS", "secret": "PRIVATE"]
        let body: [String: Any] = ["exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "message": "PRIVATE"], "faultingThread": 0, "threads": [["frames": [["imageIndex": 0, "imageOffset": 42, "symbol": "PRIVATE"]]]], "usedImages": [["uuid": uuid, "path": "/PRIVATE"]]]
        var data = try JSONSerialization.data(withJSONObject: header); data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: body))
        try data.write(to: directory.appendingPathComponent("neuraOS-test.ips"))
        let summaries = Diagnostics.crashSummaries(root: directory)
        XCTAssertEqual(summaries.first?["type"], "EXC_BAD_ACCESS")
        XCTAssertEqual(summaries.first?["frames"], "\(uuid)+42")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: summaries), as: UTF8.self).contains("PRIVATE"))
    }
    func testUncleanExitPreservesPreviousSessionAndBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: directory)}
        let old = DiagnosticEvent(time: Date(), session: "previous-session", build: "old-build", event: "session.start", operation: nil, operationId: nil, durationMs: nil, code: nil)
        try JSONEncoder().encode(old).write(to: directory.appendingPathComponent("session-999999"))
        let log = Diagnostics(directory: directory)
        log.start(); log.flush(); log.stop()
        let contents = try String(contentsOf: directory.appendingPathComponent("app.jsonl"), encoding: .utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try contents.split(separator: "\n").map {try decoder.decode(DiagnosticEvent.self, from: Data($0.utf8))}
        let recovered = try XCTUnwrap(events.first {$0.event == "session.unclean"})
        XCTAssertEqual(recovered.session, "previous-session")
        XCTAssertEqual(recovered.build, "old-build")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session-999999").path))
    }
    func testStorageFailureDoesNotBreakRecording() {
        let log = Diagnostics(directory: URL(fileURLWithPath: "/dev/null/impossible"))
        log.record("operation.failure"); log.flush()
    }
}
