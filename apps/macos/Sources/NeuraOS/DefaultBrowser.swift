import SwiftUI
import AppKit
import Observation
import ChromiumBridge

/// Web links other apps hand to neuraOS (as the default browser) until a worktree on screen opens them.
@MainActor @Observable final class ExternalLinks {
    static let shared = ExternalLinks()
    private(set) var pending: [URL] = []
    /// Set by the main scene: shows (or re-creates) the main window so a worktree can take the links.
    @ObservationIgnored var showMain: (() -> Void)?
    @ObservationIgnored private var fallback: Task<Void, Never>?

    func receive(_ urls: [URL], fallbackAfter delay: Duration = .seconds(10)) {
        let accepted = urls.filter(Self.accepts)
        guard !accepted.isEmpty else {return}
        pending += accepted
        showMain?()
        // App-lifetime safety net: nothing on screen took them (main scene gone, UI stuck).
        fallback?.cancel()
        fallback = Task {[weak self] in
            do {try await Task.sleep(for: delay)} catch {return}
            self?.openInExtensionWindow()
        }
    }

    func take() -> [URL] {
        fallback?.cancel(); fallback = nil
        defer {pending = []}
        return pending
    }

    /// Returns the first error, if any page could not be opened.
    @discardableResult func openInExtensionWindow() -> String? {
        var failure: String?
        for url in take() {
            if let error = NCOpenExtensionWindow(url.absoluteString) {failure = failure ?? error; NSLog("External link: %@", error)}
        }
        return failure
    }

    /// Only ordinary web pages; credentials in the URL are refused like the address field does.
    nonisolated static func accepts(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {return false}
        return true
    }
}

enum DefaultBrowser {
    static let schemes = ["http", "https"]

    static func handler(for scheme: String, workspace: NSWorkspace = .shared) -> URL? {
        URL(string: "\(scheme)://example.com").flatMap {workspace.urlForApplication(toOpen: $0)}
    }

    static func isDefault() -> Bool {schemes.allSatisfy(isDefault(scheme:))}

    enum SetupError: LocalizedError {
        case notBundled
        var errorDescription: String? {"アプリとしてパッケージされたneuraOS（.app）から設定してください。"}
    }

    /// macOS asks the user to confirm the change of default browser.
    @MainActor static func makeDefault() async throws {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {throw SetupError.notBundled}
        for scheme in schemes where !isDefault(scheme: scheme) {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
        }
    }

    /// "Open in another browser": while neuraOS is the default, the system default would hand the page straight back.
    static func openOutside(_ url: URL, workspace: NSWorkspace = .shared) {
        let own = Bundle.main.bundleIdentifier
        guard handler(for: url.scheme ?? "https").flatMap({Bundle(url: $0)?.bundleIdentifier}) == own else {workspace.open(url); return}
        let others = workspace.urlsForApplications(toOpen: url).filter {Bundle(url: $0)?.bundleIdentifier != own}
        guard let app = others.first(where: {Bundle(url: $0)?.bundleIdentifier == "com.apple.Safari"}) ?? others.first else {return}
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func isDefault(scheme: String) -> Bool {
        guard let own = Bundle.main.bundleIdentifier else {return false}
        return handler(for: scheme).flatMap {Bundle(url: $0)?.bundleIdentifier} == own
    }
}

struct DefaultBrowserSettings: View {
    @State private var isDefault = DefaultBrowser.isDefault()
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("デフォルトのWebブラウザ").font(.headline)
            Text("ほかのアプリで開いたリンクを、表示中のWorkspaceの新しいブラウザタブで開きます。Workspaceが表示されていないときは、拡張対応ウィンドウで開きます。")
            HStack {
                Button("neuraOSをデフォルトのブラウザにする") {
                    busy = true; message = nil
                    Task {
                        do {try await DefaultBrowser.makeDefault()} catch {message = error.localizedDescription}
                        isDefault = DefaultBrowser.isDefault(); busy = false
                    }
                }.disabled(isDefault || busy)
                if isDefault {Label("デフォルトのブラウザです", systemImage: "checkmark.circle.fill").foregroundStyle(.green)}
            }
            Text("macOSの確認で「“neuraOS”を使用」を選んでください。元に戻すには、システム設定 → デスクトップとDock → デフォルトのWebブラウザ で変更します。")
                .font(.callout).foregroundStyle(.secondary)
            if let message {Text(message).font(.callout).textSelection(.enabled)}
        }.padding(24).frame(width: 520)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {_ in isDefault = DefaultBrowser.isDefault()}
    }
}
