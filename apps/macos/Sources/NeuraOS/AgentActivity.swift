import SwiftUI

enum AgentActivity: String {
    case working, waiting, idle, unknown, stopped
    var label: String {
        switch self {
        case .working: return "作業中"
        case .waiting: return "回答・承認待ち"
        case .idle: return "次の指示待ち"
        case .unknown: return "状態不明"
        case .stopped: return "停止"
        }
    }
}

struct WorkspaceActivity {
    let agents: [TerminalRecord]
    let connected: Bool
    init(terminals: [TerminalRecord], connected: Bool) {
        // Old stopped tabs must not drown out the current sessions.
        let agents = terminals.filter {$0.provider == "codex" || $0.provider == "claude"}
        let live = agents.filter {$0.status == "running"}
        self.agents = live.isEmpty ? agents : live
        self.connected = connected
    }
    func state(_ terminal: TerminalRecord) -> AgentActivity {
        guard connected else {return .unknown}
        guard terminal.status == "running" else {return .stopped}
        return AgentActivity(rawValue: terminal.activity ?? "unknown") ?? .unknown
    }
    var activity: AgentActivity? {
        guard !agents.isEmpty else {return nil}
        let states = agents.map(state)
        return [AgentActivity.waiting, .working, .unknown, .idle, .stopped].first {states.contains($0)}
    }
    var waitingCount: Int {agents.filter {state($0) == .waiting}.count}
    var help: String {
        var lines = agents.map {"\($0.provider == "codex" ? "Codex" : "Claude Code"): \(state($0).label)"}
        if !connected {lines.append("Daemonへの接続を確認しています")}
        else if agents.contains(where: {$0.status == "running" && state($0) == .unknown}) {
            lines.append("状態連携を待っています。Codexでフックの確認が表示された場合は /hooks を開いてください。")
        }
        return lines.joined(separator: "\n")
    }
}

struct WorkspaceActivityIndicator: View {
    let terminals: [TerminalRecord]
    let connected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var summary: WorkspaceActivity {WorkspaceActivity(terminals: terminals, connected: connected)}

    var body: some View {
        if let activity = summary.activity {
            Group {
                switch activity {
                case .working:
                    if reduceMotion {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
                    } else {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    }
                case .waiting:
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.bubble.fill")
                        if summary.waitingCount > 1 {Text("\(summary.waitingCount)").font(.system(size: 9, weight: .semibold)).monospacedDigit()}
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.13), in: Capsule())
                case .idle:
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                case .unknown:
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                case .stopped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .frame(minWidth: 14, minHeight: 16)
            .help(summary.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.help)
        }
    }
}
