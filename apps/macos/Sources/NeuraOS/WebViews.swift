import SwiftUI
import ChromiumBridge

@MainActor final class BrowserModel: ObservableObject {
    let view: NCChromiumView
    @Published var address: String
    @Published var title = ""
    @Published var message: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    let storageId: String
    let workspaceId: String
    let projectId: String
    var tabId: String {String(storageId.split(separator: ".").last ?? "")}
    var browserVisible = true
    @Published var automationEnabled = true {
        didSet {UserDefaults.standard.set(!automationEnabled, forKey: "browser.mcpDisabled." + storageId)}
    }
    @Published var automationOwner = ""
    private var observedURL = ""

    init(storageId: String, workspaceId: String, projectId: String, view: NCChromiumView? = nil) {
        self.storageId = storageId; self.workspaceId = workspaceId; self.projectId = projectId
        automationEnabled = !UserDefaults.standard.bool(forKey: "browser.mcpDisabled." + storageId)
        address = Self.savedAddress(storageId: storageId, workspaceId: workspaceId)
        self.view = view ?? NCChromiumView(frame: .zero)
        self.view.onState = { [weak self] url, title, back, forward, loading in
            DispatchQueue.main.async {
                guard let self else {return}
                self.title = title
                // CEF callbacks arrive on its UI thread (the AppKit main thread).
                self.canGoBack = back; self.canGoForward = forward; self.isLoading = loading
                if loading {self.message = nil}
                if !url.isEmpty, url != self.observedURL {
                    self.observedURL = url; self.address = url
                    UserDefaults.standard.set(url, forKey: "browser.\(self.storageId)")
                }
            }
        }
        self.view.onError = { [weak self] message in DispatchQueue.main.async {self?.message = message} }
        self.view.onAutomationInvalidated = { [weak self] reason in
            DispatchQueue.main.async {if let self {BrowserAutomation.shared.stop(self, reason: reason)}}
        }
        // A popup already owns a Chromium navigation/opener. Do not reload it.
        if view == nil {navigate()}
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
    static func navigationURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "about:blank" {return URL(string: value)}
        guard !value.isEmpty else {return nil}
        let normalized = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {return nil}
        return url
    }
    func navigate() {
        guard let url = Self.navigationURL(address) else {message = "httpまたはhttpsのURLを入力してください。"; return}
        message = nil; address = url.absoluteString
        UserDefaults.standard.set(address, forKey: "browser.\(storageId)")
        view.loadURL(address)
    }
}

struct BrowserPane: View {
    let visible: Bool
    @Binding var title: String?
    let onPopup: (NCChromiumView, String) -> Bool
    let onClosed: () -> Void
    @StateObject private var browser: BrowserModel
    init(storageId: String, workspaceId: String, projectId: String, visible: Bool, title: Binding<String?>, view: NCChromiumView? = nil,
         onPopup: @escaping (NCChromiumView, String) -> Bool, onClosed: @escaping () -> Void) {
        self.visible = visible; self._title = title; self.onPopup = onPopup; self.onClosed = onClosed
        _browser = StateObject(wrappedValue: BrowserModel(storageId: storageId, workspaceId: workspaceId, projectId: projectId, view: view))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {browser.view.goBack()} label: {Image(systemName: "chevron.left")}.help("戻る").disabled(!browser.canGoBack)
                Button {browser.view.goForward()} label: {Image(systemName: "chevron.right")}.help("進む").disabled(!browser.canGoForward)
                Button {if browser.isLoading {browser.view.stop()} else {browser.view.reload()}} label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                }.help(browser.isLoading ? "読み込みを停止" : "再読み込み")
                TextField("URL", text: $browser.address).textFieldStyle(.roundedBorder).onSubmit {browser.navigate()}
                Button {browser.navigate()} label: {Image(systemName: "arrow.right")}.help("開く")
                Button {if let url = BrowserModel.navigationURL(browser.address), url.scheme != "about" {NSWorkspace.shared.open(url)}} label: {
                    Image(systemName: "arrow.up.right.square")
                }.help("デフォルトのブラウザで開く")
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 34)
            HStack {
                Text(browser.automationOwner.isEmpty ? (browser.automationEnabled ? "MCP接続可・同じプロジェクト" : "MCP接続解除中") : "MCP操作中 · \(browser.automationOwner.prefix(8))")
                Spacer()
                Button(browser.automationEnabled ? "停止・接続解除" : "MCP接続を再開") {
                    if browser.automationEnabled {BrowserAutomation.shared.stop(browser)} else {browser.automationEnabled = true}
                }
            }.font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
            if let message = browser.message {Text(message).font(.system(size: 11)).foregroundStyle(.secondary).padding(8)}
            BrowserWebView(browser: browser, visible: visible, onPopup: onPopup, onClosed: onClosed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onChange(of: browser.title) {_, value in title = value.isEmpty ? nil : value}
    }
}
struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel
    let visible: Bool
    let onPopup: (NCChromiumView, String) -> Bool
    let onClosed: () -> Void
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NCChromiumView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }
    func makeNSView(context: Context) -> NCChromiumView {browser.view}
    func updateNSView(_ view: NCChromiumView, context: Context) {
        browser.browserVisible = visible
        view.isHidden = !visible
        view.onPopup = onPopup
        view.onClosed = {DispatchQueue.main.async {onClosed()}}
    }
    static func dismantleNSView(_ view: NCChromiumView, coordinator: ()) {BrowserAutomation.shared.unregister(view); view.onClosed = nil; view.close()}
}
