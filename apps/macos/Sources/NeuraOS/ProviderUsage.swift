import SwiftUI

struct ProviderUsageFooter: View {
    @EnvironmentObject var model: AppModel
    @State private var refreshing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) {context in
            HStack(spacing: 16) {
                Text("使用済み").foregroundStyle(.secondary)
                ForEach(["claude", "codex"], id: \.self) {provider in
                    let usage = model.providerUsage.first {$0.provider == provider}
                    HStack(spacing: 6) {
                        Image(systemName: provider == "claude" ? "asterisk" : "sparkle")
                            .accessibilityLabel(provider == "codex" ? "Codex" : "Claude")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(provider == "claude" ? Color.orange : Color.primary)
                        if !model.connected {Text("未接続").foregroundStyle(.secondary)}
                        else if model.state.features?.contains("provider.usage") != true {Text("更新が必要").foregroundStyle(.secondary)}
                        else if let usage {
                            if usage.isStale(at: context.date) {Text("更新待ち").foregroundStyle(.secondary)}
                            else if usage.status == "available" && !usage.windows.isEmpty {
                                ForEach(Array(usage.windows.enumerated()), id: \.offset) {index, window in
                                    if index > 0 {Text("·").foregroundStyle(.tertiary)}
                                    Text(window.label).foregroundStyle(.secondary)
                                    Text(window.percentage)
                                        .foregroundStyle(window.usedPercent >= 90 ? Color.orange : Color.primary)
                                    if let remaining = window.resetCountdown(at: context.date) {
                                        Text(remaining).foregroundStyle(.secondary)
                                    }
                                }
                            } else {Text(usage.status == "available" ? "情報なし" : usage.statusLabel).foregroundStyle(.secondary)}
                        } else {Text(model.usageFailed ? "取得できません" : "取得中…").foregroundStyle(.secondary)}
                    }
                    .help("\(provider == "codex" ? "Codex" : "Claude")\n\(usage?.details ?? "アカウント共通の5時間・週間の利用枠を表示します。")")
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
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, 12).frame(height: 28)
        }
    }
}
