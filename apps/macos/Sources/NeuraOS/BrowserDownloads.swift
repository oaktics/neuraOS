import SwiftUI
import ChromiumBridge

// Copy callback values so SwiftUI sees progress changes even when the CEF model identity is stable.
struct DownloadSnapshot {
    let identifier: UInt
    let name: String
    let path: String
    let status: String
    let detail: String
    let received: Int64
    let total: Int64
    private let download: NCDownload
    init(_ download: NCDownload) {
        self.download = download
        identifier = download.identifier; name = download.name; path = download.path
        status = download.status; detail = download.detail
        received = download.received; total = download.total
    }
    func cancel() { download.cancel() }
    func reveal() { download.reveal() }
}

@MainActor final class BrowserDownloads: ObservableObject {
    static let shared = BrowserDownloads()
    @Published var items: [DownloadSnapshot] = []
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName: .NCBrowserDownloadsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.items = NCBrowserDownloads().map(DownloadSnapshot.init) }
        }
        items = NCBrowserDownloads().map(DownloadSnapshot.init)
    }
}

struct BrowserDownloadsButton: View {
    @ObservedObject private var downloads = BrowserDownloads.shared
    @State private var presented = false
    private var active: Int { downloads.items.filter { ["choosing", "running"].contains($0.status) }.count }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                if active > 0 { Text("\(active)").monospacedDigit() }
            }
        }
        .help("ダウンロード")
        .accessibilityLabel("ダウンロード")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("ダウンロード").font(.headline).padding()
                Divider()
                if downloads.items.isEmpty {
                    Text("ダウンロードはありません").foregroundStyle(.secondary).padding(24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(downloads.items, id: \.identifier) { item in
                                DownloadRow(item: item)
                                Divider()
                            }
                        }
                    }.frame(maxHeight: 360)
                }
            }.frame(width: 380)
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadSnapshot
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.status == "failed" ? "exclamationmark.triangle" : "doc")
                .font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(item.detail).font(.caption).foregroundStyle(item.status == "failed" ? .red : .secondary)
                if item.status == "running" {
                    if item.total > 0 { ProgressView(value: min(Double(item.received), Double(item.total)), total: Double(item.total)) }
                    else { ProgressView().controlSize(.small) }
                    Text(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file) + (item.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file) : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !item.path.isEmpty { Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if ["choosing", "running"].contains(item.status) {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle") }.help("ダウンロードをキャンセル").accessibilityLabel("ダウンロードをキャンセル")
            } else if item.status == "complete" {
                Button { item.reveal() } label: { Image(systemName: "magnifyingglass") }.help("Finderで表示").accessibilityLabel("Finderで表示")
            }
        }.buttonStyle(.plain).padding(12)
    }
}
