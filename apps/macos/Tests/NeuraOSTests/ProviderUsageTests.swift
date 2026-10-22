import XCTest
import SwiftUI
import AppKit
@testable import NeuraOS

final class ProviderUsageTests: XCTestCase {
    @MainActor func testFooterFitsNarrowSidebar() throws {
        let model = AppModel(startPolling: false)
        model.connected = true
        model.state.features = ["provider.usage"]
        let timestamp = ISO8601DateFormatter().string(from: Date())
        model.providerUsage = [
            ProviderUsage(provider: "codex", status: "available", windows: [UsageWindow(label: "5h", usedPercent: 100, resetsAt: nil), UsageWindow(label: "週", usedPercent: 100, resetsAt: nil)], checkedAt: timestamp),
            ProviderUsage(provider: "claude", status: "available", windows: [UsageWindow(label: "5h", usedPercent: 0, resetsAt: nil), UsageWindow(label: "週", usedPercent: 2, resetsAt: nil)], checkedAt: timestamp),
        ]
        for scheme: ColorScheme in [.light, .dark] {
            let host = NSHostingView(rootView: ProviderUsageFooter().environmentObject(model)
                .padding(12).frame(width: 176).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 176, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 176, accuracy: 1)
            XCTAssertLessThan(host.fittingSize.height, 100)
            if let directory = ProcessInfo.processInfo.environment["NEURA_USAGE_SNAPSHOTS"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("usage-\(scheme).png"))
            }
        }
    }
    func testDecodeQuotaAndStaleness() throws {
        let json = #"{"providers":[{"provider":"codex","status":"available","windows":[{"label":"週","usedPercent":30,"resetsAt":"2026-10-27T06:35:18.000Z"}],"checkedAt":"2026-10-22T05:00:00.000Z"}]}"#
        let usage = try JSONDecoder().decode(ProviderUsageResponse.self, from: Data(json.utf8)).providers[0]
        XCTAssertEqual(usage.windows[0].percentage, "30%")
        XCTAssertFalse(usage.isStale(at: ProviderUsage.date("2026-10-22T05:01:00Z")!))
        XCTAssertTrue(usage.isStale(at: ProviderUsage.date("2026-10-22T05:03:00Z")!))
        XCTAssertTrue(usage.details.contains("リセット"))
        XCTAssertEqual(UsageWindow(label: "5h", usedPercent: 0, resetsAt: nil).percentage, "0%")
    }
    func testUnavailableNeverBecomesZero() throws {
        let json = #"{"providers":[{"provider":"claude","status":"unavailable","windows":[],"checkedAt":"invalid"}]}"#
        let usage = try JSONDecoder().decode(ProviderUsageResponse.self, from: Data(json.utf8)).providers[0]
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertEqual(usage.statusLabel, "取得できません")
        XCTAssertTrue(usage.isStale(at: Date()))
    }
}
