import AppKit

/// External handoff only; neuraOS no longer registers as a web URL handler.
enum DefaultBrowser {
    /// Old installations may still be the system default. Select an explicit
    /// other app so Launch Services cannot route the URL straight back to us.
    static func openOutside(_ url: URL, workspace: NSWorkspace = .shared) {
        guard let app = outsideApplication(
            defaultApplication: workspace.urlForApplication(toOpen: url),
            candidates: workspace.urlsForApplications(toOpen: url),
            ownIdentifier: Bundle.main.bundleIdentifier,
            identifier: {Bundle(url: $0)?.bundleIdentifier}
        ) else {return}
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func outsideApplication(defaultApplication: URL?, candidates: [URL], ownIdentifier: String?,
                                   identifier: (URL) -> String?) -> URL? {
        func isExternal(_ app: URL) -> Bool {
            guard let id = identifier(app) else {return false}
            return id != ownIdentifier && id != "app.neuraos.native"
        }
        if let app = defaultApplication, isExternal(app) {return app}
        let others = candidates.filter(isExternal)
        return others.first {identifier($0) == "com.apple.Safari"} ?? others.first
    }
}
