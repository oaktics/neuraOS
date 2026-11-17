import AppKit
import SwiftUI

/// Isolated packaged visual harness; no helper, preferences or network access.
@MainActor enum SleepHistoryFixture {
    static func run(_ path: String) {
        guard Bundle.main.bundleIdentifier == "com.neuraos.sleep-history-test" else {exit(2)}
        let directory = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                    Text("閉蓋時の動作 · 全状態").font(.title2.bold())
                    Text("シミュレーション / 実機の電源状態ではありません").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(SleepFooterState.Kind.allCases.enumerated()), id: \.offset) {_, kind in
                        HStack {
                            SleepStatusPill(state: .init(kind: kind, reason: kind == .unknown ? "確認が古い" : ""))
                            Spacer()
                            Text(String(describing: kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("クリック → 詳細・履歴　　オン／オフ → 独立した設定").font(.caption)
                }.padding(24).frame(width: 580).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.frame = CGRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                window.orderFront(nil)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {exit(3)}
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {exit(4)}
                try data.write(to: directory.appendingPathComponent(dark ? "footer-dark.png" : "footer-light.png"))
                window.orderOut(nil)
            }
            exit(0)
        } catch {fputs("Sleep fixture failed: \(error)\n", stderr); exit(1)}
    }
}
