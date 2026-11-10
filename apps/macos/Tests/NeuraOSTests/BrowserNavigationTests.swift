import XCTest
import SwiftTerm
import SwiftUI
@testable import NeuraOS

final class BrowserNavigationTests: XCTestCase {
    @MainActor func testBrowserAddressesRejectLocalFilesAndEmbeddedCredentials() {
        XCTAssertEqual(BrowserModel.navigationURL(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertEqual(BrowserModel.navigationURL("http://localhost:3000")?.host, "localhost")
        XCTAssertEqual(BrowserModel.navigationURL("about:blank")?.absoluteString, "about:blank")
        for input in ["", "file:///etc/passwd", "javascript://alert(1)", "https://user:secret@example.com"] {
            XCTAssertNil(BrowserModel.navigationURL(input), input)
        }
    }
    @MainActor func testLinksOpenNewSelectedTabsWithWorkspaceScopedAddresses() throws {
        let suite = "BrowserLinksTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let terminal = WorkspaceTab(kind: "shell")
        var layout = WorkspaceTabState(tabs: [terminal], selectedId: terminal.id)
        let firstURL = try XCTUnwrap(URL(string: "https://github.com/org/repo/pull/1#discussion"))
        XCTAssertTrue(layout.openBrowser(firstURL, workspaceId: "workspace-a", defaults: defaults))
        let first = try XCTUnwrap(layout.tabs.last)
        XCTAssertEqual(layout.selectedId, first.id)
        XCTAssertEqual(first.kind, "browser")
        XCTAssertEqual(BrowserModel.savedAddress(storageId: "workspace-a.\(first.id)", workspaceId: "workspace-a", defaults: defaults), firstURL.absoluteString)
        XCTAssertNil(defaults.string(forKey: "browser.workspace-b.\(first.id)"))
        XCTAssertTrue(layout.openBrowser(URL(string: "http://localhost:3000")!, workspaceId: "workspace-a", defaults: defaults))
        XCTAssertEqual(layout.tabs.last?.number, 2)
        XCTAssertNotEqual(layout.selectedId, first.id)
        XCTAssertEqual(layout.tabs.first, terminal)
        XCTAssertEqual(defaults.string(forKey: "browser.workspace-a.\(first.id)"), firstURL.absoluteString)
        let selected = layout.selectedId
        for value in ["file:///etc/passwd", "mailto:person@example.com", "javascript:alert(1)", "https://user:secret@example.com"] {
            XCTAssertFalse(layout.openBrowser(URL(string: value)!, workspaceId: "workspace-a", defaults: defaults))
        }
        XCTAssertEqual(layout.tabs.count, 3)
        XCTAssertEqual(layout.selectedId, selected)
    }

    @MainActor func testAgentLinksRemainScopedAfterTabRemovalAndReordering() throws {
        let suite = "BrowserAgentLinks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        for provider in ["codex", "claude"] {
            let workspace = "workspace-" + provider
            let conversation = WorkspaceTab(kind: provider, terminalId: provider)
            var layout = WorkspaceTabState(tabs: [conversation], selectedId: conversation.id)
            let record = TerminalRecord(id: provider, workspaceId: workspace, provider: provider, status: "running", cols: 80, rows: 24)
            let coordinator = NativeTerminal.Coordinator(terminal: record, api: DaemonClient(), onError: {_ in XCTFail()})
            coordinator.openLink = {_ = layout.openBrowser($0, workspaceId: workspace, defaults: defaults)}
            let view = TerminalView(frame: .zero)
            for index in 0..<3 {
                coordinator.requestOpenLink(source: view, link: "https://example.com/\(index)", params: [:])
                let tab = try XCTUnwrap(layout.tabs.last)
                XCTAssertEqual(layout.selectedId, tab.id)
                XCTAssertEqual(defaults.string(forKey: "browser.\(workspace).\(tab.id)"), "https://example.com/\(index)")
                XCTAssertNil(defaults.string(forKey: "browser.other.\(tab.id)"))
                layout.tabs.reverse()
                layout.tabs.removeAll {$0.kind == "browser"}
                XCTAssertEqual(layout.tabs, [conversation])
            }
        }
    }

    @MainActor func testRenderedAgentClicksUseExplicitWorkspaceRouteInsteadOfOpenURLEnvironment() throws {
        _ = NSApplication.shared
        let suite = "RenderedAgentLinks.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        for provider in ["codex", "claude"] {
            let workspace = "workspace-" + provider
            var layout = WorkspaceTabState()
            let record = TerminalRecord(id: provider, workspaceId: workspace, provider: provider, status: "exited", cols: 80, rows: 24)
            func content(_ route: @escaping (URL) -> Void) -> some View {
                NativeTerminal(onOpenURL: route, terminal: record, api: DaemonClient(), visible: false, onError: {_ in XCTFail("Unexpected API call")})
                    .environment(\.openURL, OpenURLAction {_ in
                        XCTFail("Terminal links must not reach the system OpenURL route")
                        return .discarded
                    })
            }
            let route: (URL) -> Void = {_ = layout.openBrowser($0, workspaceId: workspace, defaults: defaults)}
            let host = NSHostingView(rootView: content(route))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func terminal(in view: NSView) -> NativeTerminalView? {
                if let terminal = view as? NativeTerminalView {return terminal}
                return view.subviews.lazy.compactMap {terminal(in: $0)}.first
            }
            let view = try XCTUnwrap(terminal(in: host))
            let coordinator = try XCTUnwrap(view.terminalDelegate as? NativeTerminal.Coordinator)
            // Avoid daemon polling: these tests exercise the real renderer and mouse route.
            coordinator.stop()
            defer {window.contentView = nil}
            for (index, url) in ["http://localhost:3000/path", "https://example.com/path#fragment"].enumerated() {
                for explicit in [false, true] {
                    view.feed(text: "\u{1b}[2J\u{1b}[H")
                    view.feed(text: explicit ? "\u{1b}]8;;\(url)\u{1b}\\click here\u{1b}]8;;\u{1b}\\" : url)
                    let point = view.convert(NSPoint(x: 8, y: view.bounds.height - 8), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
                    view.mouseUp(with: event)
                    XCTAssertEqual(layout.tabs.count, index * 2 + (explicit ? 2 : 1))
                    let tab = try XCTUnwrap(layout.tabs.last)
                    XCTAssertEqual(layout.selectedId, tab.id)
                    XCTAssertEqual(defaults.string(forKey: "browser.\(workspace).\(tab.id)"), url)
                    XCTAssertNil(defaults.string(forKey: "browser.other.\(tab.id)"))
                }
            }
            // A reused representable must replace, rather than retain, its prior callback.
            var updated: [URL] = []
            host.rootView = content {updated.append($0)}
            host.layoutSubtreeIfNeeded()
            view.terminalDelegate?.requestOpenLink(source: view, link: "https://updated.example", params: [:])
            XCTAssertEqual(updated.map(\.absoluteString), ["https://updated.example"])
            XCTAssertEqual(layout.tabs.count, 4)
        }
    }

    func testBrowserTitleUsesExistingWorkspaceTabAndRestoresLegacyTabs() throws {
        let old = Data("{\"id\":\"old\",\"kind\":\"browser\",\"number\":2}".utf8)
        var tab = try JSONDecoder().decode(WorkspaceTab.self, from: old)
        XCTAssertEqual(tab.title, "Browser 2")
        tab.browserTitle = "Gmail"
        XCTAssertEqual(tab.title, "Gmail")
        let restored = try JSONDecoder().decode(WorkspaceTab.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(restored.title, "Gmail")
        XCTAssertEqual(restored.id, "old")
    }
}
