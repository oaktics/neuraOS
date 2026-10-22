import SwiftUI

struct ProviderUsageFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) {context in
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.bottom, 3)
                Text("利用枠 · アカウント共通").font(.system(size: 9)).foregroundStyle(.tertiary)
                ForEach(["codex", "claude"], id: \.self) {provider in
                    let usage = model.providerUsage.first {$0.provider == provider}
                    HStack(spacing: 5) {
                        Text(provider == "codex" ? "Codex" : "Claude").foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        if !model.connected {Text("未接続").foregroundStyle(.tertiary)}
                        else if model.state.features?.contains("provider.usage") != true {Text("更新が必要").foregroundStyle(.tertiary)}
                        else if let usage {
                            if usage.isStale(at: context.date) {Text("更新待ち").foregroundStyle(.tertiary)}
                            else if usage.status == "available" {
                                ForEach(Array(usage.windows.enumerated()), id: \.offset) {_, window in
                                    Text("\(window.label) \(window.percentage)")
                                        .foregroundStyle(window.usedPercent >= 90 ? Color.orange : Color.secondary)
                                }
                            } else {Text(usage.statusLabel).foregroundStyle(.tertiary)}
                        } else {Text(model.usageFailed ? "取得できません" : "取得中…").foregroundStyle(.tertiary)}
                    }
                    .font(.system(size: 10)).monospacedDigit().lineLimit(1)
                    .help(usage?.details ?? "アカウント共通の5時間・週間の利用枠を表示します。")
                }
            }
        }
    }
}
