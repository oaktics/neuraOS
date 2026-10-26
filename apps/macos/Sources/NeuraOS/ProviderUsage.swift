import SwiftUI

struct ProviderUsageFooter: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) {context in
            HStack(spacing: 12) {
                AgentSleepFooter(controller: model.agentSleep)
                Rectangle().fill(Palette.line).frame(width: 1, height: 12)
                ForEach(["claude", "codex"], id: \.self) {provider in
                    let usage = model.providerUsage.first {$0.provider == provider}
                    HStack(spacing: 6) {
                        Image(systemName: provider == "claude" ? "asterisk" : "sparkle")
                            .accessibilityLabel(provider == "codex" ? "Codex" : "Claude")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(provider == "claude" ? Color.orange : Color.primary)
                        if !model.connected {Text("—").foregroundStyle(.secondary)}
                        else if model.state.features?.contains("provider.usage") != true {Text("—").foregroundStyle(.secondary)}
                        else if let usage {
                            if usage.isStale(at: context.date) {Text("—").foregroundStyle(.secondary)}
                            else if usage.status == "available" && !usage.windows.isEmpty {
                                ForEach(Array(usage.windows.enumerated()), id: \.offset) {index, window in
                                    if index > 0 {Text("·").foregroundStyle(.tertiary)}
                                    Text(window.label).foregroundStyle(.secondary)
                                    Text(window.percentage)
                                        .foregroundStyle(window.usedPercent >= 90 ? Color.orange : Color.primary)
                                }
                            } else {Text("—").foregroundStyle(.secondary)}
                        } else {Text(model.usageFailed ? "—" : "…").foregroundStyle(.secondary)}
                    }
                    .help(usageHelp(provider: provider, usage: usage, at: context.date))
                    .accessibilityValue(usageHelp(provider: provider, usage: usage, at: context.date))
                    .accessibilityElement(children: .combine)
                }
                Button {
                    refreshing = true
                    Task {
                        await model.refreshUsage()
                        refreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(refreshing || !model.connected || model.state.features?.contains("provider.usage") != true)
                .help("利用状況を更新").accessibilityLabel("利用状況を更新")
            }
            .font(.system(size: 11)).monospacedDigit().lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 28)
        }
    }
    private func usageHelp(provider: String, usage: ProviderUsage?, at date: Date) -> String {
        var lines = [provider == "codex" ? "Codex" : "Claude"]
        if !model.connected {lines.append("未接続")}
        else if model.state.features?.contains("provider.usage") != true {lines.append("更新が必要")}
        else if let usage {
            if usage.isStale(at: date) {lines.append("更新待ち")}
            else if usage.status != "available" {lines.append(usage.statusLabel)}
            else if usage.windows.isEmpty {lines.append("情報なし")}
            for window in usage.windows {
                if let remaining = window.resetCountdown(at: date) {
                    lines.append("\(window.label): リセットまで \(remaining)")
                }
            }
            lines.append(usage.details)
        } else {lines.append(model.usageFailed ? "取得できません" : "取得中…")}
        return lines.joined(separator: "\n")
    }
}
