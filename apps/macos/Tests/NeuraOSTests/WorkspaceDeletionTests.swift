import XCTest
import AppKit
@testable import NeuraOS

private final class DeletionProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest, [String: Any]) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool {request.url?.host == "deletion-test.invalid"}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer {stream.close()}
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 {break}; data.append(contentsOf: bytes.prefix(count))
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Self.lock.lock()
            let result: (Int, Data)
            do {result = try Self.handler!(request, body); Self.lock.unlock()}
            catch {Self.lock.unlock(); throw error}
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self, didFailWithError: error)}
    }
    override func stopLoading() {}
}

final class WorkspaceDeletionTests: XCTestCase {
    private func workspace(_ id: String = "deletion-fixture") -> Workspace {
        Workspace(id: id, projectId: "project", name: "Fixture", path: "/nonexistent", branch: "test", kind: "worktree")
    }
    private func job(_ status: String = "running", phase: String = "remove-files", revision: Int = 2,
                     retryable: Bool = false, blocks: Bool = true, code: String? = nil) -> DeletionJob {
        DeletionJob(id: "job", workspaceId: "deletion-fixture", status: status, phase: phase, revision: revision,
                    createdAt: "2026-11-09T00:00:00Z", updatedAt: "2026-11-09T00:00:01Z",
                    error: code.map {DeletionJob.Failure(code: $0, message: "削除できません")}, retryable: retryable, blocksWorkspace: blocks, generation: 1)
    }
    private func snapshot(_ deletion: DeletionJob? = nil, jobs: Bool = true) -> Snapshot {
        var w = workspace(); w.deletion = deletion
        return Snapshot(features: jobs ? ["workspace.delete.jobs", "workspace.delete.discard", "terminal.multiple"] : ["workspace.delete", "workspace.delete.stop-terminals"], workspaces: [w, workspace("other")])
    }

    @MainActor func testAcceptedJobRemainsPresentUntilSnapshotRemovalAndNeverRollsBack() throws {
        let model = AppModel(startPolling: false)
        model.applySnapshot(snapshot()); model.openedIds = [workspace().id]
        try model.acceptDeletion(DeletionAccepted(ok: true, accepted: true, job: job("queued", phase: "queued", revision: 1)), workspaceId: workspace().id)
        XCTAssertEqual(model.state.workspaces.count, 2)
        XCTAssertTrue(model.openedIds.contains(workspace().id))
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        XCTAssertFalse(model.isWorkspaceBlocked("other"))
        model.applySnapshot(snapshot()) // Fetch already in flight at acceptance.
        XCTAssertEqual(model.deletion(workspace().id)?.status, "queued")
        model.applySnapshot(snapshot(job(revision: 4)))
        model.applySnapshot(snapshot(job("queued", revision: 1)))
        XCTAssertEqual(model.deletion(workspace().id)?.revision, 4)
        model.applySnapshot(snapshot(job("succeeded", phase: "completed", revision: 5)))
        XCTAssertEqual(model.state.workspaces.count, 2)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        var gone = snapshot(); gone.workspaces.removeFirst()
        model.applySnapshot(gone)
        XCTAssertNil(model.deletion(workspace().id))
        XCTAssertFalse(model.openedIds.contains(workspace().id))
    }

    @MainActor func testNewAcceptedJobSurvivesOlderFailedJobSnapshot() throws {
        let model = AppModel(startPolling: false)
        let old = job("failed", retryable: true, blocks: false, code: "workspace_dirty")
        model.applySnapshot(snapshot(old))
        let next = DeletionJob(id: "new-job", workspaceId: workspace().id, status: "queued", phase: "queued", revision: 1,
                               createdAt: "2026-11-08T00:00:00Z", updatedAt: "2026-11-08T00:00:00Z", retryable: false, blocksWorkspace: true, generation: 2)
        try model.acceptDeletion(DeletionAccepted(ok: true, accepted: true, job: next), workspaceId: workspace().id)
        model.applySnapshot(snapshot(old))
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        model.applySnapshot(snapshot(next))
        model.applySnapshot(snapshot(old))
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
    }

    @MainActor func testSnapshotGenerationBeatsClockRollbackAndLateAcceptance() throws {
        let model = AppModel(startPolling: false)
        let old = job("failed", retryable: true, blocks: false, code: "workspace_dirty")
        model.applySnapshot(snapshot(old))
        let newer = DeletionJob(id: "new-job", workspaceId: workspace().id, status: "running", phase: "remove-files", revision: 1,
                                createdAt: "2020-01-01T00:00:00Z", updatedAt: "2020-01-01T00:00:00Z", retryable: false, blocksWorkspace: true, generation: 2)
        model.applySnapshot(snapshot(newer))
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        try model.acceptDeletion(DeletionAccepted(ok: true, accepted: true, job: old), workspaceId: workspace().id)
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        model.applySnapshot(snapshot(old))
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        var legacy = old; legacy.generation = nil
        model.applySnapshot(snapshot(legacy))
        XCTAssertEqual(model.deletion(workspace().id)?.id, old.id, "Without generations, different-job snapshot is authoritative")
    }

    func testSnapshotMergePerformsOneIndexedLookupPerWorkspaceWithoutJobs() {
        let workspaces = (0..<2_000).map {workspace("w\($0)")}
        let previous: [String: DeletionJob] = [:]
        var accepted: [String: DeletionJob] = [:]
        var lookups = 0
        let merged = DeletionSnapshotMerge.apply(workspaces, previousJob: {id in
            lookups += 1
            return previous[id]
        }, accepted: &accepted)
        XCTAssertEqual(lookups, workspaces.count)
        XCTAssertEqual(merged, workspaces)
        XCTAssertTrue(accepted.isEmpty)
    }

    @MainActor func testRestartAndReconnectRestoreFailedJobAndGuards() async {
        let model = AppModel(startPolling: false)
        let failed = job("failed", retryable: true, blocks: true, code: "remove_failed")
        model.applySnapshot(snapshot(failed)); model.updateConnection(false)
        XCTAssertEqual(model.deletion(workspace().id)?.error?.message, "削除できません")
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        XCTAssertFalse(model.beginAction(workspace().id, label: "起動"))
        XCTAssertTrue(model.beginAction("other", label: "起動")); model.endAction("other")
        let opened = await model.openTerminal(workspace())
        XCTAssertNil(opened)
        model.updateConnection(true); model.applySnapshot(snapshot(failed))
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        model.applySnapshot(snapshot(job("failed", revision: 3, retryable: true, blocks: false, code: "workspace_dirty")))
        XCTAssertFalse(model.isWorkspaceBlocked(workspace().id))
        XCTAssertNil(model.pendingWorkspaceDeletion) // Reconnect never discards or opens a destructive dialog.
    }

    @MainActor func testUncertainStartAndRetryPersistAndReplayExactOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        defer {try? FileManager.default.removeItem(at: directory)}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {session.invalidateAndCancel()}
        let api = DaemonClient(endpoint: URL(string: "http://deletion-test.invalid")!, dataDirectory: directory, session: session)
        let model = AppModel(startPolling: false, api: api)
        var current = snapshot()
        var bodies: [[String: Any]] = []
        var reply: DeletionJob?
        DeletionProtocol.handler = {request, body in
            if request.httpMethod == "POST" {
                bodies.append(body)
                guard let reply else {throw URLError(.timedOut)}
                let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply))
                return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "accepted": true, "job": value]))
            }
            return (200, try JSONEncoder().encode(current))
        }
        defer {DeletionProtocol.handler = nil}
        model.applySnapshot(current); model.connected = true
        await model.deleteWorkspace(workspace(), discardChanges: true)
        let intent = try XCTUnwrap(model.deletionIntents[workspace().id])
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        model.applySnapshot(snapshot()) // Detached command may still be awaiting admission.
        model.applySnapshot(snapshot(job("failed", blocks: false)))
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        await model.deleteWorkspace(workspace())
        await model.retryDeletion(workspace())
        XCTAssertEqual(bodies.count, 1)
        let restored = AppModel(startPolling: false, api: api)
        restored.applySnapshot(snapshot()); restored.connected = true
        XCTAssertEqual(restored.deletionIntents[workspace().id], intent)
        XCTAssertTrue(restored.isWorkspaceBlocked(workspace().id))
        reply = DeletionJob(id: intent.operationId, workspaceId: workspace().id, status: "failed", phase: "verify-before", revision: 2, createdAt: "", updatedAt: "", retryable: true, blocksWorkspace: false, generation: 1)
        current = snapshot(reply)
        await restored.confirmDeletionAcceptance(workspace().id)
        XCTAssertEqual(bodies[0]["operationId"] as? String, bodies[1]["operationId"] as? String)
        XCTAssertEqual(bodies[0]["command"] as? NSDictionary, bodies[1]["command"] as? NSDictionary)
        XCTAssertEqual((bodies[1]["command"] as? [String: Any])?["discardChanges"] as? Bool, true)
        XCTAssertFalse(restored.isWorkspaceBlocked(workspace().id))
        reply = nil
        await restored.retryDeletion(workspace())
        let retry = try XCTUnwrap(restored.deletionIntents[workspace().id])
        restored.applySnapshot(current) // Same old failed revision cannot resolve retry.
        XCTAssertTrue(restored.isWorkspaceBlocked(workspace().id))
        await restored.retryDeletion(workspace())
        XCTAssertEqual(bodies.count, 3)
        reply = DeletionJob(id: intent.operationId, workspaceId: workspace().id, status: "running", phase: "stop-terminals", revision: 3, createdAt: "", updatedAt: "", retryable: true, blocksWorkspace: true, generation: 1)
        restored.applySnapshot(snapshot(reply)) // Another retry could produce this revision.
        XCTAssertEqual(restored.deletionIntents[workspace().id], retry)
        await restored.confirmDeletionAcceptance(workspace().id)
        XCTAssertEqual(bodies[2]["operationId"] as? String, bodies[3]["operationId"] as? String)
        XCTAssertEqual(bodies[2]["command"] as? NSDictionary, bodies[3]["command"] as? NSDictionary)
        XCTAssertTrue(restored.deletionIntents.isEmpty)
        // Exact start-job evidence also resolves after a lost reply, without replay.
        try restored.saveDeletionIntent(intent)
        restored.applySnapshot(snapshot(reply))
        XCTAssertTrue(restored.deletionIntents.isEmpty)
    }

    @MainActor func testAbsentWorkspaceIntentRecoveryIsBoundedAndNeedsDefinitiveProof() async throws {
        for finalRejection in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "fixture".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
            defer {try? FileManager.default.removeItem(at: directory)}
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DeletionProtocol.self]
            let session = URLSession(configuration: configuration)
            defer {session.invalidateAndCancel()}
            let api = DaemonClient(endpoint: URL(string: "http://deletion-test.invalid")!, dataDirectory: directory, session: session)
            let intent = DeletionIntent(workspaceId: workspace().id, request: .init(type: "workspace.delete.start", workspaceId: workspace().id, discardChanges: false, stopTerminals: true), baseline: nil)
            try AppModel(startPolling: false, api: api).saveDeletionIntent(intent)
            let restored = AppModel(startPolling: false, api: api)
            var absent = snapshot(); absent.workspaces.removeFirst()
            var requests: [[String: Any]] = []
            var definitive = false
            DeletionProtocol.handler = {request, body in
                if request.httpMethod == "POST" {
                    requests.append(body)
                    guard definitive else {throw URLError(.timedOut)}
                    if finalRejection {
                        return (409, try JSONEncoder().encode(APIError(error: "workspace_missing", message: "削除対象なし", operationId: intent.operationId, operationFinal: true)))
                    }
                    let job = DeletionJob(id: intent.operationId, workspaceId: intent.workspaceId, status: "succeeded", phase: "completed", revision: 8, createdAt: "", updatedAt: "", retryable: false, blocksWorkspace: false, verifiedAbsent: true, generation: 1)
                    return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "accepted": true, "job": JSONSerialization.jsonObject(with: JSONEncoder().encode(job))]))
                }
                return (200, try JSONEncoder().encode(absent))
            }
            defer {DeletionProtocol.handler = nil}
            restored.applySnapshot(absent)
            XCTAssertEqual(restored.deletionIntents[intent.workspaceId], intent)
            restored.updateConnection(true)
            for task in restored.deletionRecoveryTasks.values {await task.value}
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(restored.deletionIntents[intent.workspaceId], intent)
            for _ in 0..<5 {await restored.refresh()}
            XCTAssertEqual(requests.count, 1, "No per-refresh mutation loop")
            definitive = true
            restored.updateConnection(false); restored.updateConnection(true)
            for task in restored.deletionRecoveryTasks.values {await task.value}
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[0]["operationId"] as? String, intent.operationId)
            XCTAssertEqual(requests[1]["operationId"] as? String, intent.operationId)
            XCTAssertEqual(requests[0]["command"] as? NSDictionary, requests[1]["command"] as? NSDictionary)
            XCTAssertTrue(restored.deletionIntents.isEmpty)
            XCTAssertTrue(AppModel(startPolling: false, api: api).deletionIntents.isEmpty)
            XCTAssertNil(restored.pendingActions[intent.workspaceId])
        }
    }

    @MainActor func testLegacyJournalFailureAllowlistForFirstRequestAndExactReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        defer {try? FileManager.default.removeItem(at: directory)}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {session.invalidateAndCancel()}
        let api = DaemonClient(endpoint: URL(string: "http://deletion-test.invalid")!, dataDirectory: directory, session: session)
        let model = AppModel(startPolling: false, api: api)
        let current = snapshot(jobs: false)
        model.applySnapshot(current); model.connected = true
        var failure = APIError(error: "git_failed", message: "Gitの削除に失敗")
        var bodies: [[String: Any]] = []
        DeletionProtocol.handler = {request, body in
            if request.httpMethod == "POST" {
                bodies.append(body)
                return (409, try JSONEncoder().encode(failure))
            }
            return (200, try JSONEncoder().encode(current))
        }
        defer {DeletionProtocol.handler = nil}
        await model.deleteWorkspace(workspace())
        XCTAssertEqual(bodies.count, 1, "A final legacy failure must not send a second POST")
        XCTAssertFalse(model.isWorkspaceBlocked(workspace().id))
        XCTAssertEqual(model.error, failure.message)
        XCTAssertNil(model.pendingWorkspaceDeletion)
        let intent = DeletionIntent(workspaceId: workspace().id, request: .init(type: "workspace.delete", workspaceId: workspace().id, discardChanges: false, stopTerminals: true), baseline: nil)
        for unsafe in ["operation_unknown", "operation_conflict", "storage_failed", "connection", "operation_failed", "process_cleanup_failed", "git_timeout", "cancelled"] {
            try model.saveDeletionIntent(intent)
            failure = APIError(error: unsafe, message: unsafe)
            await model.confirmDeletionAcceptance(workspace().id)
            XCTAssertEqual(model.deletionIntents[workspace().id], intent)
        }
        for marker in [APIError(error: "git_failed", message: "failure", operationFinal: false),
                       APIError(error: "git_failed", message: "failure", operationId: "another-operation")] {
            failure = marker
            await model.confirmDeletionAcceptance(workspace().id)
            XCTAssertEqual(model.deletionIntents[workspace().id], intent)
        }
        failure = APIError(error: "git_failed", message: "Gitの削除に失敗")
        let beforeReplay = bodies.count
        await model.confirmDeletionAcceptance(workspace().id)
        XCTAssertEqual(bodies.count, beforeReplay + 1)
        XCTAssertTrue(model.deletionIntents.isEmpty)
        XCTAssertFalse(model.isWorkspaceBlocked(workspace().id))
        XCTAssertEqual(model.error, failure.message)
        XCTAssertNil(model.pendingWorkspaceDeletion)
        XCTAssertTrue(bodies.dropFirst().allSatisfy {($0["operationId"] as? String) == intent.operationId})
        try model.saveDeletionIntent(intent)
        failure = APIError(error: "workspace_dirty", message: "変更あり")
        await model.confirmDeletionAcceptance(workspace().id)
        XCTAssertTrue(model.deletionIntents.isEmpty)
        XCTAssertNil(model.pendingWorkspaceDeletion, "Replay must not open a new discard confirmation")
        await model.deleteWorkspace(workspace())
        XCTAssertNotNil(model.pendingWorkspaceDeletion, "Initial legacy dirty failure preserves explicit confirmation")
    }

    @MainActor func testOnlyMatchingJournaledRejectionResolvesUnknownIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        defer {try? FileManager.default.removeItem(at: directory)}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {session.invalidateAndCancel()}
        let api = DaemonClient(endpoint: URL(string: "http://deletion-test.invalid")!, dataDirectory: directory, session: session)
        let model = AppModel(startPolling: false, api: api)
        model.applySnapshot(snapshot()); model.connected = true
        let intent = DeletionIntent(workspaceId: workspace().id, request: .init(type: "workspace.delete.start", workspaceId: workspace().id, discardChanges: false, stopTerminals: true), baseline: nil)
        try model.saveDeletionIntent(intent)
        var failure = APIError(error: "setup_running", message: "セットアップ中")
        var operations: [String] = []
        DeletionProtocol.handler = {request, body in
            if request.httpMethod == "POST" {
                operations.append(body["operationId"] as! String)
                return (409, try JSONEncoder().encode(failure))
            }
            return (200, try JSONEncoder().encode(self.snapshot()))
        }
        defer {DeletionProtocol.handler = nil}
        await model.confirmDeletionAcceptance(workspace().id)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        failure.operationFinal = true; failure.operationId = "other-operation"
        await model.confirmDeletionAcceptance(workspace().id)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        failure.operationId = intent.operationId; failure.operationFinal = false
        await model.confirmDeletionAcceptance(workspace().id)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        failure.operationFinal = true
        await model.confirmDeletionAcceptance(workspace().id)
        XCTAssertFalse(model.isWorkspaceBlocked(workspace().id))
        XCTAssertEqual(Set(operations), [intent.operationId])
        XCTAssertTrue(AppModel(startPolling: false, api: api).deletionIntents.isEmpty)
        XCTAssertNil(model.pendingWorkspaceDeletion)
    }

    @MainActor func testDiscardButtonSubmitsDirectlyAndKeepsSafetyGuards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        defer {try? FileManager.default.removeItem(at: directory)}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {session.invalidateAndCancel()}
        let api = DaemonClient(endpoint: URL(string: "http://deletion-test.invalid")!, dataDirectory: directory, session: session)
        let model = AppModel(startPolling: false, api: api)
        var commands: [[String: Any]] = []
        var current = snapshot(job("failed", retryable: false, blocks: false, code: "workspace_ignored_files"))
        DeletionProtocol.handler = {request, body in
            if request.httpMethod == "POST" {
                commands.append(body["command"] as! [String: Any])
                let accepted = self.job("queued", phase: "queued", revision: 3)
                current = self.snapshot(accepted)
                return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "accepted": true,
                    "job": JSONSerialization.jsonObject(with: JSONEncoder().encode(accepted))]))
            }
            return (200, try JSONEncoder().encode(current))
        }
        defer {DeletionProtocol.handler = nil}
        model.applySnapshot(current); model.connected = true
        await model.retryDeletion(workspace())
        XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(model.pendingWorkspaceDeletion)
        await model.discardFailedDeletion(workspace())
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0]["type"] as? String, "workspace.delete.start")
        XCTAssertEqual(commands[0]["discardChanges"] as? Bool, true)
        XCTAssertNil(model.pendingWorkspaceDeletion, "The explicit discard button must not open a second confirmation")
        await model.discardFailedDeletion(workspace())
        XCTAssertEqual(commands.count, 1, "An accepted job cannot be submitted again")
        model.applySnapshot(snapshot(job("failed", revision: 4, blocks: true, code: "workspace_dirty")))
        await model.discardFailedDeletion(workspace())
        XCTAssertEqual(commands.count, 1, "An isolated directory cannot be replaced with a new discard job")
        model.applySnapshot(snapshot(job("failed", revision: 5, blocks: false, code: "workspace_dirty")))
        model.connected = false
        await model.discardFailedDeletion(workspace())
        XCTAssertEqual(commands.count, 1)
        model.connected = true
        var unsupported = snapshot(job("failed", revision: 6, blocks: false, code: "workspace_dirty"))
        unsupported.features = ["workspace.delete.jobs"]
        model.applySnapshot(unsupported)
        await model.discardFailedDeletion(workspace())
        XCTAssertEqual(commands.count, 1)
        XCTAssertThrowsError(try model.acceptDeletion(DeletionAccepted(ok: true, accepted: false, job: job()), workspaceId: workspace().id))
        XCTAssertThrowsError(try model.acceptDeletion(DeletionAccepted(ok: true, accepted: true, job: job()), workspaceId: "other"))
    }

    @MainActor func testStartAndRetryUseShortAcceptedCommandsAndPreventDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "fixture".write(to: directory.appendingPathComponent("daemon-token"), atomically: true, encoding: .utf8)
        defer {try? FileManager.default.removeItem(at: directory)}
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DeletionProtocol.self]
        let session = URLSession(configuration: configuration); defer {session.invalidateAndCancel()}
        let model = AppModel(startPolling: false, api: DaemonClient(endpoint: URL(string: "http://deletion-test.invalid")!, dataDirectory: directory, session: session))
        var current = snapshot()
        var commands: [[String: Any]] = []
        let accepted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job("queued", phase: "queued", revision: 5)))
        let retried = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job("queued", phase: "queued", revision: 7)))
        DeletionProtocol.handler = {request, body in
            if request.httpMethod == "POST" {
                commands.append(body["command"] as! [String: Any])
                XCTAssertEqual(request.timeoutInterval, commands.last?["type"] as? String == "workspace.delete" ? 240 : 15)
                return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "accepted": true, "job": (commands.last?["type"] as? String == "workspace.deletion.retry" ? retried : accepted)]))
            }
            return (200, try JSONEncoder().encode(current))
        }
        defer {DeletionProtocol.handler = nil}
        model.applySnapshot(current); model.connected = true
        async let first: Void = model.deleteWorkspace(workspace())
        async let duplicate: Void = model.deleteWorkspace(workspace())
        _ = await (first, duplicate)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["type"] as? String, "workspace.delete.start")
        XCTAssertEqual(commands.first?["discardChanges"] as? Bool, false)
        XCTAssertEqual(model.state.workspaces.count, 2)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        current = snapshot(job("failed", revision: 6, retryable: true, blocks: true, code: "remove_failed"))
        model.applySnapshot(current)
        async let retry: Void = model.retryDeletion(workspace())
        async let duplicateRetry: Void = model.retryDeletion(workspace())
        _ = await (retry, duplicateRetry)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?["type"] as? String, "workspace.deletion.retry")
        XCTAssertEqual(commands.last?["jobId"] as? String, "job")
        XCTAssertNil(commands.last?["discardChanges"])
        XCTAssertEqual(model.deletion(workspace().id)?.revision, 7)
        current = snapshot(jobs: false)
        let legacy = AppModel(startPolling: false, api: model.api)
        legacy.applySnapshot(current); legacy.connected = true
        await legacy.deleteWorkspace(workspace())
        XCTAssertEqual(commands.last?["type"] as? String, "workspace.delete")
        XCTAssertEqual(commands.last?["discardChanges"] as? Bool, false)
    }

    @MainActor func testBlockedNativeEditorDropsFocusAndQueuedEdits() {
        _ = NSApplication.shared
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.makeFirstResponder(editor)
        NativeTextEditor.configureInteraction(editor, visible: false, editable: false)
        XCTAssertFalse(editor.isEditable)
        XCTAssertFalse(window.firstResponder === editor)
        NativeTextEditor.configureInteraction(editor, visible: true, editable: true)
        XCTAssertTrue(editor.isEditable)
    }

    func testWireContractLabelsAndLegacyTimeout() throws {
        let encoded = try JSONEncoder().encode(snapshot(job()))
        let decoded = try JSONDecoder().decode(Snapshot.self, from: encoded)
        XCTAssertEqual(decoded.workspaces.first?.deletion?.label, "作業フォルダを削除しています")
        XCTAssertEqual(DaemonClient.commandTimeout("workspace.delete.start"), 15)
        XCTAssertEqual(DaemonClient.commandTimeout("workspace.deletion.retry"), 15)
        XCTAssertEqual(DaemonClient.commandTimeout("workspace.delete"), 240)
        XCTAssertNil(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace())).deletion)
    }
}
