import AppKit
import SwiftUI

// Runs inside the packaged executable, in a disposable HOME/data directory.
// Exercises SwiftUI accessibility actions, not merely the action's model method.
@MainActor enum ReliabilitySmoke {
    static func run(report: URL) {
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.neuraos.reliability-smoke.") == true,
              Bundle.main.object(forInfoDictionaryKey: "NeuraDataDirectory") as? String == report.deletingLastPathComponent().path else {
            FileHandle.standardError.write(Data("Reliability smoke requires an isolated test bundle and data directory.\n".utf8))
            exit(2)
        }
        Diagnostics.shared.start()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let model = AppModel(startPolling: false)
        model.showSidebar = true
        model.showInspector = false
        let workspace = Workspace(id: "smoke-workspace", projectId: "smoke-project", name: "Smoke", path: report.deletingLastPathComponent().path, branch: "", kind: "folder")
        model.state.projects = [Project(id: workspace.projectId, name: "Smoke", path: workspace.path, isGit: false)]
        model.state.workspaces = [workspace]
        let first = WorkspaceTab(kind: "shell", number: 1)
        let second = WorkspaceTab(kind: "shell", number: 2)
        let storageKey = "workspaceTabs.\(workspace.id)"
        UserDefaults.standard.set(try? JSONEncoder().encode(WorkspaceTabState(tabs: [first, second], selectedId: first.id)), forKey: storageKey)
        model.select(workspace.id)
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let button = findButton(host, label: "左サイドバーを閉じる") else {throw SmokeFailure.missingButton}
                guard press(button) else {throw SmokeFailure.pressFailed}
                try await Task.sleep(for: .milliseconds(100))
                guard !model.showSidebar else {throw SmokeFailure.noEffect}
                // Background work must not disable navigation in the real view.
                model.beginAction("smoke-background", label: "確認中")
                try await Task.sleep(for: .milliseconds(100))
                guard let reopen = findButton(host, label: "左サイドバーを開く"), press(reopen) else {throw SmokeFailure.pressFailed}
                try await Task.sleep(for: .milliseconds(100))
                guard model.showSidebar else {throw SmokeFailure.noEffect}
                guard let tab = findButton(host, label: second.title), press(tab) else {throw SmokeFailure.missingButton}
                try await Task.sleep(for: .milliseconds(150))
                guard let saved = UserDefaults.standard.data(forKey: storageKey), try JSONDecoder().decode(WorkspaceTabState.self, from: saved).selectedId == second.id else {throw SmokeFailure.noEffect}
                guard let close = findButton(host, label: "\(second.title)を閉じる"), press(close) else {throw SmokeFailure.missingButton}
                try await Task.sleep(for: .milliseconds(150))
                guard let closed = UserDefaults.standard.data(forKey: storageKey), try JSONDecoder().decode(WorkspaceTabState.self, from: closed).tabs.count == 1 else {throw SmokeFailure.noEffect}
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
        if attribute(accessible, "accessibilityLabel") as? String == label {return accessible}
        for child in (attribute(accessible, "accessibilityChildren") as? [Any]) ?? (accessible as? NSView)?.subviews ?? [] {
            if let found = findButton(child, label: label, depth: depth + 1) {return found}
        }
        return nil
    }
    private enum SmokeFailure: Error {case missingButton, pressFailed, noEffect}
}
