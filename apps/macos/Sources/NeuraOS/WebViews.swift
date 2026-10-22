import SwiftUI
import WebKit

@MainActor final class BrowserModel: ObservableObject {
    let webView: WKWebView
    @Published var address: String
    @Published var message: String?
    let storageId: String
    init(storageId: String) {
        self.storageId = storageId
        address = UserDefaults.standard.string(forKey: "browser.\(storageId)") ?? "http://localhost:3000"
        // Browser content gets no terminal/API bridge and no daemon credentials.
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }
    func navigate() {
        let value = address.contains("://") ? address : "https://" + address
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {message = "httpまたはhttpsのURLを入力してください。"; return}
        message = nil; address = value; UserDefaults.standard.set(value, forKey: "browser.\(storageId)"); webView.load(URLRequest(url: url))
    }
}
struct BrowserPane: View {
    let visible: Bool
    @StateObject private var browser: BrowserModel
    init(storageId: String, visible: Bool) {self.visible = visible; _browser = StateObject(wrappedValue: BrowserModel(storageId: storageId))}
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {browser.webView.goBack()} label: {Image(systemName: "chevron.left")}.help("戻る")
                Button {browser.webView.goForward()} label: {Image(systemName: "chevron.right")}.help("進む")
                Button {browser.webView.reload()} label: {Image(systemName: "arrow.clockwise")}.help("再読み込み")
                TextField("URL", text: $browser.address).textFieldStyle(.roundedBorder).onSubmit {browser.navigate()}
                Button {browser.navigate()} label: {Image(systemName: "arrow.right")}.help("開く")
            }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 34)
            if let message = browser.message {Text(message).font(.system(size: 11)).foregroundStyle(.secondary).padding(8)}
            if visible {BrowserWebView(browser: browser, visible: true).frame(maxWidth: .infinity, maxHeight: .infinity)} else {Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)}
        }
    }
}
struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: BrowserModel
    let visible: Bool
    func makeCoordinator() -> Coordinator {Coordinator(browser)}
    func makeNSView(context: Context) -> WKWebView {browser.webView.navigationDelegate = context.coordinator; browser.webView.uiDelegate = context.coordinator; return browser.webView}
    func updateNSView(_ view: WKWebView, context: Context) {view.isHidden = !visible}
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let browser: BrowserModel
        init(_ browser: BrowserModel) {self.browser = browser}
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {browser.address = webView.url?.absoluteString ?? browser.address; UserDefaults.standard.set(browser.address, forKey: "browser.\(browser.storageId)")}
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {browser.message = error.localizedDescription}
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {decisionHandler(["http", "https", "about"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel)}
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {if navigationAction.targetFrame == nil, ["http", "https"].contains(navigationAction.request.url?.scheme ?? "") {webView.load(navigationAction.request)}; return nil}
    }
}
