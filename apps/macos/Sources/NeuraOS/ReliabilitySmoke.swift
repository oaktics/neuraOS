import AppKit
import SwiftUI
import ChromiumBridge

// Runs inside the packaged executable, in a disposable HOME/data directory.
// Exercises SwiftUI accessibility actions, not merely the action's model method.
@MainActor enum ReliabilitySmoke {
    static func run(report: URL) {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.neuraos.reliability-smoke.") == true,
              Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") as? String == report.deletingLastPathComponent().path else {
            FileHandle.standardError.write(Data("Reliability smoke requires an isolated test bundle and data directory.\n".utf8))
            exit(2)
        }
        if CommandLine.arguments.contains("--with-chromium") {
            UserDefaults.standard.setVolatileDomain(["NeuraChromiumSmokeData":report.deletingLastPathComponent().path], forName:"NeuraChromiumSmoke")
            if let error = NCInitializeChromium() {FileHandle.standardError.write(Data(error.utf8)); exit(1)}
        }
        Diagnostics.shared.start()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let model = AppModel(startPolling: false)
        model.showSidebar = true
        model.showInspector = false
        let interactiveMenu = CommandLine.arguments.contains("--interactive-menu-smoke")
        let workspace = Workspace(id: "smoke-workspace", projectId: "smoke-project", name: "Smoke", path: report.deletingLastPathComponent().path, branch: "", kind: interactiveMenu ? "worktree" : "folder")
        model.state.projects = [Project(id: workspace.projectId, name: "Smoke", path: workspace.path, isGit: false)]
        model.state.workspaces = [workspace]
        let first = WorkspaceTab(kind: interactiveMenu ? "browser" : "shell", number: 1)
        let second = WorkspaceTab(kind: "shell", number: 2)
        let storageKey = "workspaceTabs.\(workspace.id)"
        UserDefaults.standard.set(try? JSONEncoder().encode(WorkspaceTabState(tabs: [first, second], selectedId: first.id)), forKey: storageKey)
        model.select(workspace.id)
        // Keep real observation updates running while native controls track clicks.
        let polling = Timer(timeInterval: 0.05, repeats: true) {_ in
            MainActor.assumeIsolated {
                let tick = model.state.revision + 1
                model.applySnapshot(Snapshot(revision: tick, features: model.state.features,
                    projects: model.state.projects, workspaces: model.state.workspaces,
                    terminals: [TerminalRecord(id: "polling-terminal", workspaceId: interactiveMenu ? workspace.id : "background",
                        provider: "codex", status: "running", cols: 80 + tick % 2, rows: 24,
                        activity: tick.isMultiple(of: 2) ? "working" : "waiting")]))
            }
        }
        RunLoop.main.add(polling, forMode: .common)
        RunLoop.main.add(polling, forMode: .modalPanel)
        let host = NSHostingView(rootView: RootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        if interactiveMenu {
            model.updateConnection(true)
            model.state.features = ["workspace.delete"]
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            app.run()
            return
        }
        Task { @MainActor in
            defer {polling.invalidate()}
            do {
                try await Task.sleep(for: .milliseconds(500))
                if CommandLine.arguments.contains("--with-chromium") {
                    let browserWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                    let browser = NCChromiumView(frame: browserWindow.contentView!.bounds)
                    var browserTitle = ""
                    browser.onState = {_, title, _, _, _ in browserTitle = title}
                    browser.onError = {error in FileHandle.standardError.write(Data("Browser smoke: \(error)\n".utf8))}
                    browserWindow.contentView = browser
                    browserWindow.orderBack(nil)
                    browser.loadURL("data:text/html,<title>modal-ready</title>")
                    for _ in 0..<100 {
                        if browserTitle == "modal-ready" {break}
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard browserTitle == "modal-ready" else {throw SmokeFailure.browserDidNotLoad(browserTitle)}
                    browserWindow.orderOut(nil)
                    window.makeKeyAndOrderFront(nil)
                    model.state.features = ["workspace.delete", "workspace.delete.discard"]
                    for _ in 0..<10 {
                        model.pendingWorkspaceDeletion = workspace
                        try await Task.sleep(for: .milliseconds(500))
                        guard let sheet = window.attachedSheet else {throw SmokeFailure.missingButton}
                        guard let cancel = findButton(sheet, label: "キャンセル"), click(cancel, in: sheet) else {throw SmokeFailure.pressFailed}
                        for _ in 0..<100 {
                            if model.pendingWorkspaceDeletion == nil && window.attachedSheet == nil {break}
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        guard model.pendingWorkspaceDeletion == nil, window.attachedSheet == nil else {throw SmokeFailure.modalNotDismissed}
                    }
                    // Also cover app-modal dialogs (the file/save panel path uses this mode).
                    let alert = NSAlert(); alert.messageText = "Modal event routing smoke"
                    alert.addButton(withTitle: "キャンセル")
                    let cancelTimer = Timer(timeInterval: 0.3, repeats: false) {_ in
                        MainActor.assumeIsolated {_ = click(alert.buttons[0].cell!, in: alert.window)}
                    }
                    RunLoop.main.add(cancelTimer, forMode: .modalPanel)
                    guard alert.runModal() == .alertFirstButtonReturn else {throw SmokeFailure.noEffect}
                    browser.loadURL("data:text/html,<title>modal-resumed</title>")
                    for _ in 0..<100 {
                        if browserTitle == "modal-resumed" {break}
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard browserTitle == "modal-resumed" else {throw SmokeFailure.browserDidNotLoad(browserTitle)}
                    browser.close(); browser.onState = nil; browserWindow.orderOut(nil)
                    FileHandle.standardOutput.write(Data("Native sheet/app-modal clicks and Chromium resume passed.\n".utf8))
                }
                guard let button = findButton(host, label: "左サイドバーを閉じる") else {throw SmokeFailure.missingButton}
                guard click(button, in: window) else {throw SmokeFailure.pressFailed}
                try await Task.sleep(for: .milliseconds(350))
                guard !model.showSidebar else {throw SmokeFailure.noEffect}
                // Background work must not disable navigation in the real view.
                model.beginAction("smoke-background", label: "確認中")
                try await Task.sleep(for: .milliseconds(100))
                guard let reopen = findButton(host, label: "左サイドバーを開く"), press(reopen) else {throw SmokeFailure.pressFailed}
                try await Task.sleep(for: .milliseconds(100))
                guard model.showSidebar else {throw SmokeFailure.noEffect}
                model.beginTerminalLaunch(first.id)
                try await Task.sleep(for: .milliseconds(100))
                guard let protectedClose = findButton(host, label: "\(first.title)を閉じる") else {throw SmokeFailure.missingButton}
                _ = press(protectedClose)
                try await Task.sleep(for: .milliseconds(100))
                guard let protected = UserDefaults.standard.data(forKey: storageKey), try JSONDecoder().decode(WorkspaceTabState.self, from: protected).tabs.count == 2 else {throw SmokeFailure.noEffect}
                guard let tab = findButton(host, label: second.title), press(tab) else {throw SmokeFailure.missingButton}
                try await Task.sleep(for: .milliseconds(150))
                guard let saved = UserDefaults.standard.data(forKey: storageKey), try JSONDecoder().decode(WorkspaceTabState.self, from: saved).selectedId == second.id else {throw SmokeFailure.noEffect}
                guard let close = findButton(host, label: "\(second.title)を閉じる"), press(close) else {throw SmokeFailure.missingButton}
                try await Task.sleep(for: .milliseconds(150))
                guard let closed = UserDefaults.standard.data(forKey: storageKey), try JSONDecoder().decode(WorkspaceTabState.self, from: closed).tabs.count == 1 else {throw SmokeFailure.noEffect}
                model.endTerminalLaunch(first.id)
                // Simulate a workspace mutation blocking the selected tab's auto-start.
                // No daemon/token exists here: an admitted attempt must surface an error.
                model.beginAction(workspace.id, label: "先行処理")
                model.state.features = ["terminal.multiple"]
                model.connected = true
                try await Task.sleep(for: .milliseconds(100))
                guard model.error == nil else {throw SmokeFailure.noEffect}
                model.endAction(workspace.id)
                for _ in 0..<100 {
                    if model.error != nil {break}
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard model.error != nil else {throw SmokeFailure.noEffect}
                model.error = nil
                model.connected = false
                try await Task.sleep(for: .milliseconds(100))
                guard let finishedClose = findButton(host, label: "\(first.title)を閉じる"), press(finishedClose) else {throw SmokeFailure.missingButton}
                try await Task.sleep(for: .milliseconds(100))
                guard let finished = UserDefaults.standard.data(forKey: storageKey), try JSONDecoder().decode(WorkspaceTabState.self, from: finished).tabs.isEmpty else {throw SmokeFailure.noEffect}
                model.endAction("smoke-background")
                try await Diagnostics.shared.export(to: report)
                Diagnostics.shared.stop()
                if let id = Bundle.main.bundleIdentifier, id.hasPrefix("com.neuraos.reliability-smoke.") {UserDefaults.standard.removePersistentDomain(forName: id)}
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Reliability UI smoke failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }
    private static func click(_ object: NSObject, in window: NSWindow) -> Bool {
        let point: NSPoint
        if let cell = object as? NSButtonCell, let view = cell.controlView {
            point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        } else if object.responds(to: NSSelectorFromString("accessibilityFrame")), let frame = object.value(forKey: "accessibilityFrame") as? NSValue {
            point = window.convertPoint(fromScreen: NSPoint(x: frame.rectValue.midX, y: frame.rectValue.midY))
        } else {return false}
        let windowNumber = window.windowNumber
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {return false}
            if type == .leftMouseUp {
                let release = Timer(timeInterval: 0.15, repeats: false) {_ in
                    MainActor.assumeIsolated {
                        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                            NSApp.postEvent(up, atStart: false)
                        }
                    }
                }
                RunLoop.main.add(release, forMode: .common)
                RunLoop.main.add(release, forMode: .modalPanel)
            } else {
                NSApp.postEvent(event, atStart: false)
            }
        }
        return true
    }
    private static func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else {return false}
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
    }
    private static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else {return nil}
        return object.perform(selector)?.takeUnretainedValue()
    }
    private static func findButton(_ element: Any, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 30, let accessible = element as? NSObject else {return nil}
        if attribute(accessible, "accessibilityLabel") as? String == label || attribute(accessible, "accessibilityTitle") as? String == label {return accessible}
        for child in (attribute(accessible, "accessibilityChildren") as? [Any]) ?? (accessible as? NSView)?.subviews ?? [] {
            if let found = findButton(child, label: label, depth: depth + 1) {return found}
        }
        return nil
    }
    private enum SmokeFailure: Error {case missingButton, pressFailed, noEffect, modalNotDismissed, browserDidNotLoad(String)}
}
