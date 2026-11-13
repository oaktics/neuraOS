import SwiftUI
import ChromiumBridge

enum BrowserCommand: Equatable {
    case reload, hardReload, back, forward, stop
    case find, findNext, findPrevious
    case zoomIn, zoomOut, zoomReset
    case copyURL, togglePin, devTools, openExternally
}

@MainActor final class BrowserModel: ObservableObject {
    private final class Weak {weak var model: BrowserModel?; init(_ model: BrowserModel) {self.model = model}}
    private static var registry: [String: Weak] = [:]
    /// The live page for a tab, if its workspace is mounted.
    static func live(_ storageId: String) -> BrowserModel? {registry[storageId]?.model}

    let view: NCChromiumView
    @Published var address: String
    @Published var title = ""
    @Published var message: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    // Chromium creates the page only once the tab has been shown (or an agent needs it).
    @Published var loaded: Bool
    @Published var finding = false
    @Published var findText = ""
    @Published var findOrdinal = 0
    @Published var findCount = 0
    @Published var findFocus = 0
    @Published var notice: String?
    let storageId: String
    let workspaceId: String
    let projectId: String
    var tabId: String {String(storageId.split(separator: ".").last ?? "")}
    var browserVisible = true { didSet { if browserVisible != oldValue { BrowserAutomation.shared.changed() } } }
    @Published var automationEnabled = true {
        didSet {UserDefaults.standard.set(!automationEnabled, forKey: "browser.mcpDisabled." + storageId)}
    }
    @Published var automationOwner = ""
    private var observedURL = ""
    private var noticeTask: Task<Void, Never>?

    init(storageId: String, workspaceId: String, projectId: String, view: NCChromiumView? = nil, eager: Bool = true) {
        self.storageId = storageId; self.workspaceId = workspaceId; self.projectId = projectId
        automationEnabled = !UserDefaults.standard.bool(forKey: "browser.mcpDisabled." + storageId)
        address = Self.savedAddress(storageId: storageId, workspaceId: workspaceId)
        loaded = eager || view != nil
        self.view = view ?? NCChromiumView(frame: .zero)
        self.view.onState = { [weak self] url, title, back, forward, loading in
            DispatchQueue.main.async {
                guard let self else {return}
                let finished = self.isLoading && !loading
                self.title = title
                // CEF callbacks arrive on its UI thread (the AppKit main thread).
                self.canGoBack = back; self.canGoForward = forward; self.isLoading = loading
                if loading {self.message = nil}
                if !url.isEmpty, url != self.observedURL {
                    self.observedURL = url; self.address = url
                    UserDefaults.standard.set(url, forKey: "browser.\(self.storageId)")
                }
                if finished, !self.observedURL.isEmpty {BrowserHistory.shared.record(self.observedURL, title: title)}
            }
        }
        self.view.onError = { [weak self] message in DispatchQueue.main.async {self?.message = message} }
        self.view.onAutomationInvalidated = { [weak self] reason in
            DispatchQueue.main.async {if let self {BrowserAutomation.shared.stop(self, reason: reason)}}
        }
        self.view.onProgress = { [weak self] value in DispatchQueue.main.async {self?.progress = value} }
        self.view.onFavicon = { [weak self] png in
            DispatchQueue.main.async {
                guard let self, !self.observedURL.isEmpty else {return}
                FaviconStore.shared.store(png, for: self.observedURL)
            }
        }
        self.view.onFind = { [weak self] ordinal, count in
            DispatchQueue.main.async {self?.findOrdinal = ordinal; self?.findCount = count}
        }
        // A popup already owns a Chromium navigation/opener. Do not reload it.
        if view == nil {navigate()}
        Self.registry[storageId] = Weak(self)
        BrowserAutomation.shared.register(self)
    }
    static func savedAddress(storageId: String, workspaceId: String, defaults: UserDefaults = .standard) -> String {
        let key = "browser.\(storageId)", legacyKey = "browser.\(workspaceId)"
        if let saved = defaults.string(forKey: key) {return saved}
        if let legacy = defaults.string(forKey: legacyKey) {
            defaults.set(legacy, forKey: key); defaults.removeObject(forKey: legacyKey); return legacy
        }
        return "https://www.google.com/"
    }
    nonisolated static func navigationURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "about:blank" {return URL(string: value)}
        guard !value.isEmpty else {return nil}
        let normalized = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {return nil}
        return url
    }
    /// Load what the user typed: an address, or a search for anything else.
    func navigate(_ input: String? = nil) {
        guard let url = BrowserInput.resolve(input ?? address) else {message = "このアドレスは開けません。httpまたはhttpsのURLか、検索語を入力してください。"; return}
        message = nil; address = url.absoluteString
        UserDefaults.standard.set(address, forKey: "browser.\(storageId)")
        view.loadURL(address)
    }
    func perform(_ command: BrowserCommand) {
        switch command {
        case .reload: loaded = true; view.reload()
        case .hardReload: loaded = true; view.reloadIgnoringCache()
        case .back: view.goBack()
        case .forward: view.goForward()
        case .stop: view.stop()
        case .find: finding = true; findFocus += 1
        case .findNext: if finding, !findText.isEmpty {view.find(findText, forward: true, next: true)} else {finding = true; findFocus += 1}
        case .findPrevious: if finding, !findText.isEmpty {view.find(findText, forward: false, next: true)}
        case .zoomIn: view.zoom(1)
        case .zoomOut: view.zoom(-1)
        case .zoomReset: view.zoom(0)
        case .copyURL:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
            flash("URLをコピーしました")
        case .devTools: view.showDevTools()
        case .openExternally:
            if let url = Self.navigationURL(address), url.scheme != "about" {NSWorkspace.shared.open(url)}
        case .togglePin: break
        }
    }
    func updateFind() {
        findOrdinal = 0; findCount = 0
        if findText.isEmpty {view.stopFinding()} else {view.find(findText, forward: true, next: false)}
    }
    func endFind() {
        finding = false; findOrdinal = 0; findCount = 0
        view.stopFinding(); view.focusContent()
    }
    func flash(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled {self?.notice = nil}
        }
    }
}

struct BrowserPane: View {
    let visible: Bool
    @Binding var title: String?
    @Binding var url: String?
    let pin: BrowserPin?
    let split: Bool
    let actions: BrowserPaneActions
    @StateObject private var browser: BrowserModel
    @FocusState private var findFocused: Bool
    init(storageId: String, workspaceId: String, projectId: String, visible: Bool, title: Binding<String?>, url: Binding<String?>,
         pin: BrowserPin? = nil, split: Bool = false, eager: Bool = true, view: NCChromiumView? = nil, actions: BrowserPaneActions) {
        self.visible = visible; self._title = title; self._url = url; self.pin = pin; self.split = split; self.actions = actions
        _browser = StateObject(wrappedValue: BrowserModel(storageId: storageId, workspaceId: workspaceId, projectId: projectId, view: view, eager: eager))
    }
    var body: some View {
        VStack(spacing: 0) {
            // In a narrow pane the address keeps its room; the extra buttons move into the ⋯ menu.
            GeometryReader {geometry in toolbar(compact: geometry.size.width < 520)}.frame(height: 34)
            ZStack(alignment: .top) {
                Rectangle().fill(Palette.line).frame(height: 1)
                if browser.isLoading {
                    GeometryReader {geometry in
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geometry.size.width * max(0.08, min(1, browser.progress)))
                            .animation(.easeOut(duration: 0.2), value: browser.progress)
                    }.frame(height: 2)
                }
            }.frame(height: 2)
            if browser.finding {findBar}
            if !browser.automationOwner.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.rays").foregroundStyle(Color.accentColor)
                    Text("エージェントが操作中 · \(browser.automationOwner.prefix(8))")
                    Spacer()
                    Button("停止して接続解除") {BrowserAutomation.shared.stop(browser)}
                }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 26).background(Color.accentColor.opacity(0.08))
            }
            if let message = browser.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if browser.loaded {
                BrowserWebView(browser: browser, visible: visible, actions: actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Restored tabs wait here until first shown, so reopening the app does not load every page.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {if visible {browser.loaded = true}; publish()}
        .onChange(of: visible) {_, value in if value {browser.loaded = true}}
        .onChange(of: browser.title) {_, _ in publish()}
        .onChange(of: browser.address) {_, _ in publish()}
    }
    private func publish() {
        title = browser.title.isEmpty ? nil : browser.title
        url = browser.address
    }
    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 6) {
            Group {
                Button {browser.perform(.back)} label: {Image(systemName: "chevron.left").frame(width: 24, height: 24)}
                    .help("戻る（⌘[）").disabled(!browser.canGoBack)
                Button {browser.perform(.forward)} label: {Image(systemName: "chevron.right").frame(width: 24, height: 24)}
                    .help("進む（⌘]）").disabled(!browser.canGoForward)
                Button {browser.perform(browser.isLoading ? .stop : .reload)} label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise").frame(width: 24, height: 24)
                }.help(browser.isLoading ? "読み込みを停止（⌘.）" : "再読み込み（⌘R）")
            }
            Button {actions.editAddress(browser.address)} label: {
                HStack(spacing: 6) {
                    if pin != nil {Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.accentColor)}
                    else if browser.address.hasPrefix("https://") {Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.tertiary)}
                    Text(browser.notice ?? BrowserInput.displayHost(browser.address))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(browser.notice == nil ? Color.primary : Color.accentColor)
                    if let path = pathSummary, browser.notice == nil {
                        Text(path).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }.help("アドレスを入力・検索（⌘L）\n\(browser.address)").accessibilityLabel("アドレス: \(browser.address)")
            if !compact {
                Button {browser.perform(.copyURL)} label: {Image(systemName: "link").frame(width: 24, height: 24)}.help("URLをコピー（⇧⌘C）")
                Button {actions.togglePin(browser.address, browser.title)} label: {
                    Image(systemName: pin == nil ? "pin" : "pin.fill").frame(width: 24, height: 24)
                        .foregroundStyle(pin == nil ? Color.primary : Color.accentColor)
                }.help(pin == nil ? "このプロジェクトにピン留め（⌘D）" : "ピン留めを解除（⌘D）")
                Button {actions.toggleSplit()} label: {
                    Image(systemName: split ? "rectangle" : "rectangle.split.2x1").frame(width: 24, height: 24)
                }.help(split ? "分割を解除（⌘\\）" : "右に並べて表示（⌘\\）")
                BrowserDownloadsButton()
            }
            Menu {
                if compact {
                    Button("URLをコピー") {browser.perform(.copyURL)}
                    Button(pin == nil ? "このプロジェクトにピン留め" : "ピン留めを解除") {actions.togglePin(browser.address, browser.title)}
                    Button(split ? "分割を解除" : "右に並べて表示") {actions.toggleSplit()}
                    Divider()
                }
                Button("ページ内を検索…") {browser.perform(.find)}
                Button("拡大") {browser.perform(.zoomIn)}
                Button("縮小") {browser.perform(.zoomOut)}
                Button("実際のサイズ") {browser.perform(.zoomReset)}
                Divider()
                Button("デフォルトのブラウザで開く") {browser.perform(.openExternally)}
                Button("開発者ツール") {browser.perform(.devTools)}
                Divider()
                Button("拡張機能を追加・管理…") {browser.message = NCOpenExtensionWindow("chrome://extensions/")}
                Button("Chrome ウェブストアを開く…") {browser.message = NCOpenExtensionWindow("https://chromewebstore.google.com/")}
                Button("このページを拡張対応ウィンドウで開く") {
                    if let url = BrowserModel.navigationURL(browser.address) {browser.message = NCOpenExtensionWindow(url.absoluteString)}
                }
                Divider()
                Toggle("エージェント（MCP）からの操作を許可", isOn: Binding(
                    get: {browser.automationEnabled},
                    set: {enabled in if enabled {browser.automationEnabled = true} else {BrowserAutomation.shared.stop(browser)}}
                ))
            } label: {
                Image(systemName: browser.automationEnabled ? "ellipsis" : "ellipsis.circle").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(browser.automationEnabled ? "その他" : "その他（エージェントからの操作は停止中）")
            if compact {BrowserDownloadsButton()}
        }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 34)
    }
    private var pathSummary: String? {
        guard let url = URL(string: browser.address), url.host != nil else {return nil}
        let path = url.path + (url.query.map {"?" + $0} ?? "")
        return path.isEmpty || path == "/" ? nil : path
    }
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("ページ内を検索", text: $browser.findText)
                .textFieldStyle(.plain).focused($findFocused)
                .onSubmit {browser.perform(NSEvent.modifierFlags.contains(.shift) ? .findPrevious : .findNext)}
                .onExitCommand {browser.endFind()}
                .onChange(of: browser.findText) {_, _ in browser.updateFind()}
            if !browser.findText.isEmpty {
                Text(browser.findCount == 0 ? "見つかりません" : "\(browser.findOrdinal) / \(browser.findCount)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Button {browser.perform(.findPrevious)} label: {Image(systemName: "chevron.up").frame(width: 22, height: 22)}
                .help("前を検索（⇧⏎）").disabled(browser.findCount == 0)
            Button {browser.perform(.findNext)} label: {Image(systemName: "chevron.down").frame(width: 22, height: 22)}
                .help("次を検索（⌘G）").disabled(browser.findCount == 0)
            Button {browser.endFind()} label: {Image(systemName: "xmark").frame(width: 22, height: 22)}.help("検索を閉じる（esc）")
        }
        .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30)
        .background(Color.primary.opacity(0.035))
        .onAppear {findFocused = true; if !browser.findText.isEmpty {browser.updateFind()}}
        .onChange(of: browser.findFocus) {_, _ in findFocused = true}
    }
}

/// What a page asks of the workspace that hosts it.
struct BrowserPaneActions {
    var popup: (NCChromiumView, String) -> Bool = {_, _ in false}
    var openTab: (String, Bool) -> Void = {_, _ in}
    var closed: () -> Void = {}
    var editAddress: (String) -> Void = {_ in}
    var togglePin: (String, String) -> Void = {_, _ in}
    var toggleSplit: () -> Void = {}
}

struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel
    let visible: Bool
    let actions: BrowserPaneActions
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NCChromiumView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }
    func makeNSView(context: Context) -> NCChromiumView {browser.view}
    func updateNSView(_ view: NCChromiumView, context: Context) {
        browser.browserVisible = visible
        view.isHidden = !visible
        view.onPopup = actions.popup
        view.onOpenTab = actions.openTab
        let closed = actions.closed
        view.onClosed = {DispatchQueue.main.async {closed()}}
    }
    static func dismantleNSView(_ view: NCChromiumView, coordinator: ()) {BrowserAutomation.shared.unregister(view); view.onClosed = nil; view.close()}
}
