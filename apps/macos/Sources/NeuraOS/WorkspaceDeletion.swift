import SwiftUI
import Observation

struct DeletionJob: Codable, Hashable, Identifiable {
    struct Failure: Codable, Hashable {let code: String; let message: String}
    let id: String
    let workspaceId: String
    let status: String
    let phase: String
    let revision: Int
    let createdAt: String
    let updatedAt: String
    var error: Failure?
    let retryable: Bool
    let blocksWorkspace: Bool
    var verifiedAbsent: Bool?
    var generation: Int? = nil

    var inProgress: Bool {status == "queued" || status == "running"}
    // Even a success response must not reopen a workspace awaiting snapshot removal.
    var preventsUse: Bool {inProgress || blocksWorkspace || status == "succeeded"}
    var needsDiscardConfirmation: Bool {
        status == "failed" && !blocksWorkspace && ["workspace_dirty", "workspace_ignored_files"].contains(error?.code ?? "")
    }
    var label: String {
        if status == "failed" {return "削除を完了できませんでした"}
        if status == "succeeded" {return verifiedAbsent == true ? "削除完了・一覧を更新中" : "削除結果を確認しています"}
        switch phase {
        case "queued": return "削除の開始を待っています"
        case "verify-before", "verify-after": return "削除できるか確認しています"
        case "stop-terminals": return "ターミナルとエージェントを終了しています"
        case "isolate": return "作業フォルダを削除する準備をしています"
        case "remove-files": return "作業フォルダを削除しています"
        case "remove-git": return "Gitの作業登録を解除しています"
        case "finalize", "completed": return "削除結果を確認しています"
        default: return "作業を削除しています"
        }
    }
}
@MainActor @Observable final class WorkspaceDeletionState {
    var job: DeletionJob?
    init(job: DeletionJob?) {self.job = job}
}

enum DeletionSnapshotMerge {
    // One indexed lookup per workspace. The caller builds the index once, so
    // snapshots without jobs also remain linear in workspace count.
    static func apply(_ workspaces: [Workspace], previousJob: (String) -> DeletionJob?,
                      accepted: inout [String: DeletionJob]) -> [Workspace] {
        workspaces.map {workspace in
            var workspace = workspace
            let incoming = workspace.deletion
            let acknowledged = accepted[workspace.id]
            let current = previousJob(workspace.id)
            let known: DeletionJob?
            if let acknowledged, let current, isOlder(acknowledged, than: current) {known = current}
            else {known = acknowledged ?? current}
            if let known, incoming == nil || isOlder(incoming!, than: known) {workspace.deletion = known}
            if let incoming, let acknowledged, !isOlder(incoming, than: acknowledged) {
                accepted.removeValue(forKey: workspace.id)
            }
            return workspace
        }
    }
    static func isOlder(_ candidate: DeletionJob, than known: DeletionJob) -> Bool {
        if candidate.id == known.id {return candidate.revision < known.revision}
        if let candidateGeneration = candidate.generation, let knownGeneration = known.generation {
            return candidateGeneration < knownGeneration
        }
        // Older daemons may omit generation. Prefer their authoritative snapshot
        // for a different job; wall-clock dates cannot establish ordering.
        return false
    }
}

// Persist the exact request before its first network side effect. Neither a
// timeout nor an unrelated snapshot can cancel a detached daemon command.
struct DeletionIntent: Codable, Equatable {
    struct Request: Codable, Equatable {
        let type: String
        var workspaceId: String? = nil
        var discardChanges: Bool? = nil
        var stopTerminals: Bool? = nil
        var jobId: String? = nil
        func command() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        }
    }
    var operationId = UUID().uuidString.lowercased()
    let workspaceId: String
    let request: Request
    let baseline: DeletionJob?
}

extension AppModel {
    private var deletionIntentURL: URL {api.dataDirectory.appendingPathComponent("ui-deletion-intents.json")}
    func loadDeletionIntents() {
        guard FileManager.default.fileExists(atPath: deletionIntentURL.path) else {return}
        do {deletionIntents = try JSONDecoder().decode([String: DeletionIntent].self, from: Data(contentsOf: deletionIntentURL))}
        catch {deletionIntentLoadFailed = true; report(error)}
    }
    private func persistDeletionIntents(_ intents: [String: DeletionIntent]) throws {
        try FileManager.default.createDirectory(at: api.dataDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(intents).write(to: deletionIntentURL, options: .atomic)
    }
    func saveDeletionIntent(_ intent: DeletionIntent) throws {
        var next = deletionIntents
        next[intent.workspaceId] = intent
        try persistDeletionIntents(next)
        deletionIntents = next
    }
    func resolveDeletionIntent(_ id: String) {
        var next = deletionIntents
        next.removeValue(forKey: id)
        do {try persistDeletionIntents(next); deletionIntents = next}
        catch {report(error)} // Keep the guard if durable removal failed.
    }
    func submitDeletionIntent(_ intent: DeletionIntent, firstAttempt: Bool = false) async {
        do {
            if intent.request.type == "workspace.delete" {
                let response: OK = try await api.command(intent.request.command(), operationId: intent.operationId)
                guard response.ok else {throw APIError(error: "invalid_deletion_response", message: "削除結果を確認できません。")}
                resolveDeletionIntent(intent.workspaceId)
                return
            }
            let response: DeletionAccepted = try await api.command(intent.request.command(), operationId: intent.operationId)
            // A start may reuse an already blocking job; the operation response
            // itself is authoritative. Retry must return its requested job.
            guard intent.request.jobId == nil || response.job.id == intent.request.jobId else {
                throw APIError(error: "invalid_deletion_response", message: "削除の受付結果を確認できません。")
            }
            try acceptDeletion(response, workspaceId: intent.workspaceId)
            resolveDeletionIntent(intent.workspaceId)
        } catch let failure as APIError where failure.operationFinal == true && failure.operationId == intent.operationId {
            resolveDeletionIntent(intent.workspaceId)
            report(failure)
        } catch let failure as APIError where firstAttempt && intent.request.type == "workspace.delete" &&
            ["workspace_dirty", "workspace_ignored_files"].contains(failure.error) {
            // The first legacy handler itself rejected this operation: no older
            // timed-out copy exists. Preserve its explicit discard confirmation.
            resolveDeletionIntent(intent.workspaceId)
            if intent.request.discardChanges != true {
                pendingWorkspaceDeletion = state.workspaces.first {$0.id == intent.workspaceId}
            } else {report(failure)}
        } catch {report(error)} // Recovery may replay only this exact persisted operation.
    }
    // One replay per retained operation per connection. Snapshot refreshes only
    // recover absent rows, whose WorkspaceView/button can no longer be reached.
    func scheduleDeletionRecovery(onlyAbsent: Bool) {
        guard connected, !deletionIntentLoadFailed, !deletionIntents.isEmpty else {return}
        let visible = onlyAbsent ? Set(state.workspaces.map(\.id)) : []
        for intent in deletionIntents.values {
            guard (!onlyAbsent || !visible.contains(intent.workspaceId)),
                  pendingActions[intent.workspaceId] == nil,
                  deletionRecoveryTasks[intent.operationId] == nil,
                  deletionRecoveryAttempted.insert(intent.operationId).inserted else {continue}
            deletionRecoveryTasks[intent.operationId] = Task { [weak self] in
                guard let self else {return}
                defer {self.deletionRecoveryTasks.removeValue(forKey: intent.operationId)}
                guard self.connected, self.deletionIntents[intent.workspaceId] == intent else {return}
                await self.confirmDeletionAcceptance(intent.workspaceId)
            }
        }
    }
    func confirmDeletionAcceptance(_ workspaceId: String) async {
        guard connected, pendingActions[workspaceId] == nil, let intent = deletionIntents[workspaceId] else {return}
        pendingDeletionRetryBegin(workspaceId)
        defer {endAction(workspaceId)}
        await submitDeletionIntent(intent)
        await refresh()
    }
}

struct DeletionAccepted: Decodable {let ok: Bool; let accepted: Bool; let job: DeletionJob}

extension AppModel {
    var supportsDeletionJobs: Bool {state.features?.contains("workspace.delete.jobs") == true}
    func deletion(_ workspaceId: String) -> DeletionJob? {state.deletion(workspaceId)}
    func isWorkspaceBlocked(_ workspaceId: String) -> Bool {
        deletionIntentLoadFailed || deletion(workspaceId)?.preventsUse == true || deletionIntents[workspaceId] != nil || pendingActions[workspaceId] == "削除を受け付けています"
    }
    func requestDiscardDeletion(_ workspace: Workspace) {
        guard deletion(workspace.id)?.needsDiscardConfirmation == true,
              state.features?.contains("workspace.delete.discard") == true,
              !isBusy(workspace.id) else {return}
        pendingWorkspaceDeletion = workspace
    }
    func retryDeletion(_ workspace: Workspace) async {
        guard connected, supportsDeletionJobs, let job = deletion(workspace.id),
              job.status == "failed", job.retryable, !deletionIntentLoadFailed, deletionIntents[workspace.id] == nil,
              pendingActions[workspace.id] == nil else {return}
        guard !DraftCache.shared.load(workspace.id).values.contains(where: {$0.dirty}) else {
            error = "未保存の編集があります。保存または破棄してから削除してください。"
            return
        }
        // A failed job may still own an isolated directory, so retry intentionally
        // bypasses the normal workspace-mutation guard, but never the submit guard.
        pendingDeletionRetryBegin(workspace.id)
        defer {endAction(workspace.id)}
        do {
            let intent = DeletionIntent(workspaceId: workspace.id, request: .init(type: "workspace.deletion.retry", jobId: job.id), baseline: job)
            try saveDeletionIntent(intent)
            await submitDeletionIntent(intent)
        } catch {report(error)}
        await refresh()
    }
}

struct WorkspaceDeletionStatus: View {
    @Environment(AppModel.self) private var model
    let workspace: Workspace
    let job: DeletionJob
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if job.inProgress {ProgressView().controlSize(.small)}
            else {Image(systemName: job.status == "failed" ? "exclamationmark.triangle" : "checkmark.circle")}
            VStack(alignment: .leading, spacing: 5) {
                Text(job.label).font(.headline)
                if let error = job.error {Text(error.message).font(.callout).textSelection(.enabled)}
                if !model.connected {Text("再接続後に削除の進捗を確認します。").font(.caption).foregroundStyle(.secondary)}
                else if job.preventsUse {Text("この作業の起動と編集は停止しています。他の作業は引き続き使えます。").font(.caption).foregroundStyle(.secondary)}
                if job.status == "failed" {
                    HStack {
                        if job.retryable {Button("削除を再試行") {Task {await model.retryDeletion(workspace)}}}
                        if job.needsDiscardConfirmation && model.state.features?.contains("workspace.delete.discard") == true {
                            Button("変更を破棄して削除…", role: .destructive) {model.requestDiscardDeletion(workspace)}
                        }
                    }.disabled(!model.connected || model.pendingActions[workspace.id] != nil || model.deletionIntents[workspace.id] != nil)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(job.status == "failed" ? Color.orange.opacity(0.09) : Color.accentColor.opacity(0.07))
    }
}
