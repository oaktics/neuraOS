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

struct DeletionAccepted: Decodable {let ok: Bool; let accepted: Bool; let job: DeletionJob}

extension AppModel {
    var supportsDeletionJobs: Bool {state.features?.contains("workspace.delete.jobs") == true}
    func deletion(_ workspaceId: String) -> DeletionJob? {state.deletion(workspaceId)}
    func isWorkspaceBlocked(_ workspaceId: String) -> Bool {
        deletion(workspaceId)?.preventsUse == true || uncertainDeletions.contains(workspaceId) || pendingActions[workspaceId] == "削除を受け付けています"
    }
    func requestDiscardDeletion(_ workspace: Workspace) {
        guard deletion(workspace.id)?.needsDiscardConfirmation == true,
              state.features?.contains("workspace.delete.discard") == true,
              !isBusy(workspace.id) else {return}
        pendingWorkspaceDeletion = workspace
    }
    func retryDeletion(_ workspace: Workspace) async {
        guard connected, supportsDeletionJobs, let job = deletion(workspace.id),
              job.status == "failed", job.retryable,
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
            let response: DeletionAccepted = try await api.command(["type": "workspace.deletion.retry", "jobId": job.id])
            try acceptDeletion(response, workspaceId: workspace.id)
        } catch let failure as APIError {report(failure)}
        catch {markDeletionUncertain(workspace.id); report(error)}
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
                    }.disabled(!model.connected || model.pendingActions[workspace.id] != nil)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(job.status == "failed" ? Color.orange.opacity(0.09) : Color.accentColor.opacity(0.07))
    }
}
