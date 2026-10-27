import AppKit
import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions

/// GFM and GitHub's embedded HTML share one layout engine. Only allowlisted
/// markup reaches the live DOM; comment scripts never execute.
struct GitHubMarkdown: View {
    let source: String
    let baseURL: URL?
    var workspaceRoot: URL? = nil
    var openFile: ((String) -> Void)? = nil
    @State private var height: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if GitHubMarkdownHTML.resourcesAvailable {
            GitHubMarkdownWebView(source: source, baseURL: baseURL, workspaceRoot: workspaceRoot, openFile: openFile, dark: colorScheme == .dark, height: $height)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(source).textSelection(.enabled)
        }
    }
}

enum GitHubMarkdownHTML {
    private static let extensionsRegistered: Void = cmark_gfm_core_extensions_ensure_registered()

    static func render(_ source: String) -> String {
        _ = extensionsRegistered
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {return ""}
        defer {cmark_parser_free(parser)}
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) {cmark_parser_attach_syntax_extension(parser, ext)}
        }
        source.withCString {cmark_parser_feed(parser, $0, source.utf8.count)}
        guard let document = cmark_parser_finish(parser) else {return ""}
        defer {cmark_node_free(document)}
        // Raw HTML is needed for details/summary. It is sanitized in a detached
        // DOM before insertion, with CSP as a second boundary.
        guard let html = cmark_render_html(document, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser)) else {return ""}
        defer {free(html)}
        return String(cString: html)
    }

    // SwiftPM's command-line build generates a Bundle.module accessor that only
    // searches in the .app root and in the build directory. Signed macOS apps
    // keep resource bundles in Contents/Resources instead.
    private static let resourceBundle: Bundle? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("NeuraOS_NeuraOS.bundle"),
           let bundle = Bundle(url: url) {return bundle}
        // Never invoke SwiftPM's fatal accessor in an installed application.
        if Bundle.main.bundleURL.pathExtension == "app" {return nil}
        return Bundle.module
    }()

    static func loadResource(_ name: String, extension ext: String, in bundle: Bundle?) -> String? {
        guard let url = bundle?.url(forResource: name, withExtension: ext) else {return nil}
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static let loadedScript = loadResource("GitHubMarkdown", extension: "js", in: resourceBundle)
    private static let loadedStyle = loadResource("GitHubMarkdown", extension: "css", in: resourceBundle)
    static var resourcesAvailable: Bool {loadedScript != nil && loadedStyle != nil}
    static let script = loadedScript ?? ""
    static let style = loadedStyle ?? ""
    static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: http: neura-workspace:; base-uri 'none'; form-action 'none'">
    <style>\(style)</style></head><body><main id="markdown"></main></body></html>
    """
}

struct GitHubMarkdownWebView: NSViewRepresentable {
    let source: String
    let baseURL: URL?
    var workspaceRoot: URL? = nil
    var openFile: ((String) -> Void)? = nil
    let dark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {Coordinator(self)}

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: GitHubMarkdownHTML.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: .defaultClient))
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "markdownHeight")
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "markdownCopy")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        if let workspaceRoot {
            configuration.setURLSchemeHandler(WorkspaceMarkdownResources(root: workspaceRoot), forURLScheme: WorkspaceMarkdownResources.scheme)
        }
        let view = GitHubMarkdownScrollingWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(GitHubMarkdownHTML.page, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdownHeight", contentWorld: .defaultClient)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdownCopy", contentWorld: .defaultClient)
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: GitHubMarkdownWebView
        var ready = false
        private var renderedSource: String?
        private var renderedBase: URL?
        private var renderedDark: Bool?
        init(_ parent: GitHubMarkdownWebView) {self.parent = parent}

        func render(_ view: WKWebView) {
            guard ready else {return}
            guard renderedSource != parent.source || renderedBase != parent.baseURL || renderedDark != parent.dark else {return}
            renderedSource = parent.source; renderedBase = parent.baseURL; renderedDark = parent.dark
            view.callAsyncJavaScript("renderMarkdown(html, base, dark)", arguments: [
                "html": GitHubMarkdownHTML.render(parent.source), "base": parent.baseURL?.absoluteString ?? "https://github.com/", "dark": parent.dark
            ], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {ready = true; render(webView)}

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "markdownCopy", let code = message.body as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                return
            }
            guard let value = message.body as? Double, value.isFinite, value > 0 else {return}
            let height = CGFloat(ceil(value))
            if abs(parent.height - height) > 0.5 {parent.height = height}
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank", !ready {
                decisionHandler(.allow); return
            }
            if action.navigationType == .linkActivated, let url = action.request.url,
               let root = parent.workspaceRoot, url.scheme == WorkspaceMarkdownResources.scheme,
               let path = try? WorkspaceMarkdownResources(root: root).relativePath(for: url) {
                parent.openFile?(path)
                decisionHandler(.cancel); return
            }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
            decisionHandler(.cancel)
        }
    }
}

/// Markdown expands to its full height, so vertical scrolling belongs to the
/// native list. Intercept before WebKit's internal content view consumes it.
final class GitHubMarkdownScrollingWebView: WKWebView {
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor {NSEvent.removeMonitor(scrollMonitor)}
        scrollMonitor = nil
        guard window != nil else {return}
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.forwardVerticalScroll(event) == true ? nil : event
        }
    }

    deinit {
        if let scrollMonitor {NSEvent.removeMonitor(scrollMonitor)}
    }

    @discardableResult
    func forwardVerticalScroll(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
              let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
              hit === self || hit.isDescendant(of: self),
              let scrollView = enclosingScrollView else {return false}
        scrollView.scrollWheel(with: event)
        return true
    }
}
