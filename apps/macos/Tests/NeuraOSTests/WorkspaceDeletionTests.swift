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
                    error: code.map {DeletionJob.Failure(code: $0, message: "削除できません")}, retryable: retryable, blocksWorkspace: blocks)
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
                               createdAt: "2026-11-09T00:00:02Z", updatedAt: "2026-11-09T00:00:02Z", retryable: false, blocksWorkspace: true)
        try model.acceptDeletion(DeletionAccepted(ok: true, accepted: true, job: next), workspaceId: workspace().id)
        model.applySnapshot(snapshot(old))
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        model.applySnapshot(snapshot(next))
        model.applySnapshot(snapshot(old))
        XCTAssertEqual(model.deletion(workspace().id)?.id, "new-job")
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
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
        model.requestDiscardDeletion(workspace())
        XCTAssertEqual(model.pendingWorkspaceDeletion?.id, workspace().id)
    }

    @MainActor func testLostAcceptanceReplyStaysBlockedUntilSnapshotRecovery() {
        let model = AppModel(startPolling: false)
        model.applySnapshot(snapshot())
        model.markDeletionUncertain(workspace().id)
        model.updateConnection(false)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
        XCTAssertFalse(model.isWorkspaceBlocked("other"))
        model.applySnapshot(snapshot(job()))
        model.updateConnection(true)
        XCTAssertTrue(model.uncertainDeletions.isEmpty)
        XCTAssertTrue(model.isWorkspaceBlocked(workspace().id))
    }

    @MainActor func testDirtyFailureNeedsExplicitDiscardAndRetryGuard() async throws {
        let model = AppModel(startPolling: false)
        model.applySnapshot(snapshot(job("failed", retryable: false, blocks: false, code: "workspace_ignored_files")))
        model.connected = true
        await model.retryDeletion(workspace()) // Must not issue a command for retryable=false.
        XCTAssertNil(model.error)
        XCTAssertTrue(model.deletion(workspace().id)!.needsDiscardConfirmation)
        model.requestDiscardDeletion(workspace())
        XCTAssertNotNil(model.pendingWorkspaceDeletion)
        model.pendingWorkspaceDeletion = nil
        model.applySnapshot(snapshot(job("failed", revision: 3, blocks: true, code: "workspace_dirty")))
        model.requestDiscardDeletion(workspace())
        XCTAssertNil(model.pendingWorkspaceDeletion)
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
