import SwiftUI

struct SleepFooterState: Equatable {
    enum Kind: CaseIterable {case continues, sleeps, checking, unknown, permission, failed, releaseGrace, connectionGrace}
    var kind: Kind
    var reason: String
    var label: String {
        switch kind {
        case .continues: return "閉蓋でも継続"
        case .sleeps: return "閉蓋でスリープ"
        case .checking: return "閉蓋動作を確認中"
        case .unknown: return "閉蓋不明 · " + reason
        case .permission: return "閉蓋不明 · 許可が必要"
        case .failed: return "閉蓋不明 · 制御失敗"
        case .releaseGrace: return "閉蓋継続 · 解除猶予"
        case .connectionGrace: return "閉蓋不明 · 接続猶予"
        }
    }
    var detail: String {
        if kind == .unknown {
            switch reason {
            case "外部の抑制": return "OS のスリープ抑制は有効ですが、このアプリによる制御は確認できません。"
            case "確認が古い": return "helper の確認が古い、または取得できないため、継続できるとは判断できません。"
            case "作業情報が古い": return "作業・接続の最新状態を確認できません。"
            case "蓋情報なし": return "この Mac の蓋の状態を取得できません。"
            case "OS情報なし": return "OS のスリープ抑制状態を取得できません。"
            default: break
            }
        }
        return reason
    }
    var icon: String {
        switch kind {
        case .continues: return "laptopcomputer"
        case .sleeps: return "moon.zzz"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        case .permission: return "lock.circle"
        case .failed: return "exclamationmark.triangle"
        case .releaseGrace, .connectionGrace: return "clock"
        }
    }
    var color: Color {
        let kind = kind
        return Color(nsColor: NSColor(name: nil) {appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch kind {
            case .continues:
                return dark ? NSColor(srgbRed: 0.44, green: 0.72, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0.36, blue: 0.65, alpha: 1)
            case .sleeps, .checking:
                return dark ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.34, alpha: 1)
            case .failed:
                return dark ? NSColor(srgbRed: 1, green: 0.58, blue: 0.58, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.14, blue: 0.10, alpha: 1)
            default:
                return dark ? NSColor(srgbRed: 0.96, green: 0.69, blue: 0.36, alpha: 1) : NSColor(srgbRed: 0.54, green: 0.29, blue: 0, alpha: 1)
            }
        })
    }
    /// OS readback is required even when the setting is off: another app can
    /// own SleepDisabled. Old helper text is never confirmation.
    static func derive(starting: Bool, stopping: Bool, permission: Bool, failed: Bool,
                       enabled: Bool, freshWork: Bool, helper: String?, sleepDisabled: Bool?, lidAvailable: Bool) -> Self {
        if starting || stopping {return .init(kind: .checking, reason: stopping ? "解除中" : "開始中")}
        if permission {return .init(kind: .permission, reason: "macOS の許可が必要")}
        if failed {return .init(kind: .failed, reason: "詳細で制御結果を確認してください")}
        guard lidAvailable else {return .init(kind: .unknown, reason: "蓋情報なし")}
        guard let sleepDisabled else {return .init(kind: .unknown, reason: "OS情報なし")}
        if !sleepDisabled {return .init(kind: .sleeps, reason: "OS の抑制は無効。通常の電源設定に従います")}
        guard enabled, let helper else {return .init(kind: .unknown, reason: enabled ? "確認が古い" : "外部の抑制")}
        if helper == "作業終了を確認中…" {return .init(kind: .releaseGrace, reason: "完了・回答待ち後、5秒の猶予で解除します")}
        if helper == "作業状態を確認できません（30秒で抑制解除）" {
            return .init(kind: .connectionGrace, reason: "作業状態不明。最大30秒で解除します")
        }
        if helper == "作業中：蓋を閉じても継続します", freshWork {
            return .init(kind: .continues, reason: "helper と OS で抑制を確認。機種・電源条件での実動作保証ではありません")
        }
        return .init(kind: .unknown, reason: freshWork ? "確認中" : "作業情報が古い")
    }
}

struct SleepStatusPill: View {
    let state: SleepFooterState
    @State private var hovering = false
    var body: some View {
        Label(state.label, systemImage: state.icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(state.color.opacity(hovering ? 0.17 : 0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(state.color.opacity(hovering ? 0.4 : 0.18), lineWidth: 1))
            .contentShape(Capsule()).onHover {hovering = $0}
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.label).accessibilityValue(state.detail)
    }
}

struct SleepPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct SleepHistoryPopover: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var controller: AgentSleepController
    @ObservedObject var history: SleepHistoryStore
    var openSession: (SleepHistoryEvent) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SleepStatusPill(state: controller.footerState)
                Spacer()
                Text("スリープと接続の履歴").font(.headline)
            }
            Text(controller.footerState.detail).font(.callout)
            Text("制御状況: \(controller.status)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Toggle("作業中の閉蓋スリープを抑制する（設定）", isOn: Binding(get: {controller.wantedSetting}, set: {controller.setWanted($0)}))
                .disabled(controller.starting || controller.stopping || controller.repairing || controller.isolated)
            if controller.approvalRequired && !controller.isolated {
                Button("システム設定で許可") {controller.openApprovalSettings()}
            }
            Divider()
            Text("OS取得 / アプリ観測 / 推定を区別しています。同時期のイベントだけでは原因を特定できません。日時はこのMacの現地時間です。")
                .font(.caption).foregroundStyle(.secondary)
            if history.storageFailed {Text("履歴の読み込み・保存に失敗しました。未保存の記録があります。").font(.caption).foregroundStyle(.red)}
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(history.events.reversed()) {event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(event.kind.label).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(event.source == .os ? "OS取得" : event.source == .inference ? "推定" : "アプリ観測")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(event.date.formatted(date: .abbreviated, time: .standard))
                                if let duration = event.duration {Text("直前状態の観測期間 \(Int(duration))秒")}
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(event.reason.label).font(.caption).foregroundStyle(.secondary)
                            if let session = event.sessionID {
                                Button("会話を開く · \(session.prefix(12))") {openSession(event)}.font(.caption)
                                Text("\(model.state.projects.first {$0.id == event.projectID}?.name ?? event.projectID ?? "プロジェクト不明") · \(model.state.workspaces.first {$0.id == event.workspaceID}?.name ?? event.workspaceID ?? "作業場所不明")")
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Divider()
                    }
                }.padding(.trailing, 4)
            }.frame(height: 300)
            Text("14日・最大2,000件 / 1 MiB。Wi-Fiは経路の可用性、到達性は固定HTTPS確認先への観測です。監視間の短い変化や停止中のイベントは取得できません。")
                .font(.caption2).foregroundStyle(.secondary)
        }.lineLimit(nil).font(.body).padding(16).frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Read-only navigation works for stopped terminals too; it never retries a turn.
struct SleepHistoryConversation: View {
    let event: SleepHistoryEvent
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [SleepConversationPage.Turn] = []
    @State private var nextCursor: String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("関連する会話").font(.headline)
                Spacer()
                Button("閉じる") {dismiss()}.keyboardShortcut(.cancelAction)
            }
            Text("Session \(event.sessionID ?? "不明")").font(.caption).textSelection(.enabled)
            if let error {Text(error).foregroundStyle(.secondary)}
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let cursor = nextCursor {Button("以前の会話を読み込む") {Task {await read(cursor)}}}
                    ForEach(turns) {turn in
                        Text("Turn \(turn.id) · \(turn.status)").font(.caption).foregroundStyle(.secondary)
                        ForEach(turn.items) {item in Text(item.display).font(.callout).textSelection(.enabled)}
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.lineLimit(nil).font(.body).padding(20).frame(width: 700, height: 560).task {await read(nil)}
    }
    private func read(_ cursor: String?) async {
        guard let id = event.sessionID else {return}
        do {
            let result: SleepConversationPage = try await model.api.get("v1/agents/\(id)", query: cursor.map {["cursor": $0]} ?? [:])
            let incoming = Array(result.history.data.reversed())
            if cursor != nil {
                let known = Set(turns.map(\.id)); turns = incoming.filter {!known.contains($0.id)} + turns
            } else {turns = incoming}
            nextCursor = result.history.nextCursor
            error = nil
        } catch {self.error = "会話を取得できません。接続またはセッションの保存状態を確認してください。"}
    }
}


private struct SleepConversationPage: Decodable {
    let history: History
    struct History: Decodable {let data: [Turn]; let nextCursor: String?}
    struct Turn: Decodable, Identifiable {let id: String; let status: String; let items: [Item]}
    struct Item: Decodable, Identifiable {
        let id: String; let text: String?; let command: String?; let aggregatedOutput: String?; let content: [Input]?
        struct Input: Decodable {let text: String?}
        var display: String {text ?? command.map {$0 + (aggregatedOutput.map {"\n" + $0} ?? "")} ?? content?.compactMap(\.text).joined(separator: "\n") ?? ""}
    }
}
