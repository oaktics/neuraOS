import AppKit
import SwiftUI
import PDFKit
import AVKit
import UniformTypeIdentifiers

enum PreviewKind: Equatable {
    case image, pdf, media, quickLook
    static func detect(_ path: String) -> Self {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" {return .pdf}
        guard let type = UTType(filenameExtension: ext) else {return .quickLook}
        if type.conforms(to: .image) {return .image}
        if type.conforms(to: .movie) || type.conforms(to: .audio) {return .media}
        return .quickLook
    }
}

struct RichFilePreview: View {
    let url: URL
    var body: some View {
        switch PreviewKind.detect(url.path) {
        case .pdf: PDFFilePreview(url: url)
        case .image: ImageFilePreview(url: url)
        case .media: MediaFilePreview(url: url)
        case .quickLook: FileQuickLook(url: url)
        }
    }
}

struct ImageFilePreview: View {
    let url: URL
    @State private var image: NSImage?
    @State private var zoom = 1.0
    @State private var fits = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("−") {fits = false; zoom = max(0.1, zoom / 1.25)}.help("縮小")
                Button("＋") {fits = false; zoom = min(8, zoom * 1.25)}.help("拡大")
                Button("実寸") {fits = false; zoom = 1}
                Button("全体表示") {fits = true}
                Spacer()
                if let rep = image?.representations.first {Text("\(rep.pixelsWide) × \(rep.pixelsHigh) px").foregroundStyle(.secondary)}
            }.controlSize(.small).padding(8)
            Divider()
            GeometryReader {geometry in
                if let image {
                    let size = pixelSize(image)
                    let scale = fits ? min(geometry.size.width / size.width, geometry.size.height / size.height, 1) : zoom
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: size.width * scale, height: size.height * scale)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                } else {ContentUnavailableView("画像を読み込めません", systemImage: "photo")}
            }
        }.task(id: url) {image = NSImage(contentsOf: url)}
    }
    private func pixelSize(_ image: NSImage) -> CGSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {return CGSize(width: max(1, image.size.width), height: max(1, image.size.height))}
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

struct MediaFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause(); view.player = AVPlayer(url: url)
        }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {view.player?.pause(); view.player = nil}
}

@MainActor final class PDFPreviewModel: NSObject, ObservableObject, @preconcurrency PDFDocumentDelegate {
    let view = PDFView()
    @Published var page = 1
    @Published var pages = 0
    @Published var matches: [PDFSelection] = []
    @Published var matchIndex = 0
    @Published var searching = false
    @Published var failure: String?
    private var observation: NSObjectProtocol?
    override init() {
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        observation = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.view.currentPage, let document = self.view.document else {return}
                self.page = document.index(for: current) + 1
            }
        }
    }
    deinit {if let observation {NotificationCenter.default.removeObserver(observation)}}
    func load(_ url: URL) {
        view.document?.cancelFindString()
        guard let document = PDFDocument(url: url) else {failure = "PDFを読み込めません。"; return}
        view.document = document
        document.delegate = self
        pages = document.pageCount
        failure = document.isLocked ? "パスワードで保護されたPDFです。外部アプリで開いてください。" : nil
    }
    func go(_ page: Int) {
        guard let target = view.document?.page(at: page - 1) else {return}
        view.go(to: target)
    }
    func search(_ query: String) {
        view.document?.cancelFindString()
        matches = []; matchIndex = 0; view.highlightedSelections = []; view.clearSelection()
        searching = !query.isEmpty
        if searching {view.document?.beginFindString(query, withOptions: .caseInsensitive)}
    }
    func didMatchString(_ instance: PDFSelection) {
        instance.color = .systemYellow
        matches.append(instance)
        if matches.count == 1 {showMatch(0)}
    }
    func documentDidEndDocumentFind(_ notification: Notification) {searching = false}
    func showMatch(_ index: Int) {
        guard !matches.isEmpty else {return}
        matchIndex = (index + matches.count) % matches.count
        view.setCurrentSelection(matches[matchIndex], animate: true)
        view.scrollSelectionToVisible(nil)
    }
}

struct PDFFilePreview: View {
    let url: URL
    @StateObject private var model = PDFPreviewModel()
    @State private var thumbnails = true
    @State private var query = ""
    @State private var pageInput = "1"
    @State private var continuous = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(isOn: $thumbnails) {Image(systemName: "sidebar.left")}.toggleStyle(.button).help("サムネイル")
                Button {model.go(model.page - 1)} label: {Image(systemName: "chevron.left")}.disabled(model.page <= 1)
                TextField("ページ", text: $pageInput).frame(width: 42).onSubmit {model.go(Int(pageInput) ?? model.page)}
                Text("/ \(model.pages)").monospacedDigit()
                Button {model.go(model.page + 1)} label: {Image(systemName: "chevron.right")}.disabled(model.page >= model.pages)
                Spacer(minLength: 0)
                Button("−") {model.view.autoScales = false; model.view.zoomOut(nil)}.help("縮小")
                Button("＋") {model.view.autoScales = false; model.view.zoomIn(nil)}.help("拡大")
                Button("全体表示") {model.view.autoScales = true}
                Toggle("連続", isOn: $continuous).toggleStyle(.button)
            }.padding(8)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("PDF内を検索", text: $query).onSubmit {model.search(query)}
                if model.searching {ProgressView().controlSize(.mini)}
                Text(model.matches.isEmpty ? "0件" : "\(model.matchIndex + 1) / \(model.matches.count)").monospacedDigit()
                Button {model.showMatch(model.matchIndex - 1)} label: {Image(systemName: "chevron.up")}.disabled(model.matches.isEmpty)
                Button {model.showMatch(model.matchIndex + 1)} label: {Image(systemName: "chevron.down")}.disabled(model.matches.isEmpty)
            }.padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            if let failure = model.failure {ContentUnavailableView(failure, systemImage: "doc.questionmark")}
            else {
                HStack(spacing: 0) {
                    if thumbnails {PDFThumbnails(view: model.view).frame(width: 110); Divider()}
                    PDFCanvas(view: model.view)
                }
            }
        }.controlSize(.small)
        .task(id: url) {model.load(url)}
        .task(id: query) {
            do {try await Task.sleep(for: .milliseconds(250))} catch {return}
            model.search(query)
        }
        .onChange(of: model.page) {_, value in pageInput = String(value)}
        .onChange(of: continuous) {_, value in model.view.displayMode = value ? .singlePageContinuous : .singlePage}
        .onDisappear {model.view.document?.cancelFindString()}
    }
}
struct PDFCanvas: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView {view}
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
struct PDFThumbnails: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.pdfView = view; thumbnails.thumbnailSize = CGSize(width: 80, height: 100)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.allowsDragging = false
        return thumbnails
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {nsView.pdfView = view}
}
