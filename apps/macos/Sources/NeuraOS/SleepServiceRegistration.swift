import Foundation
import ServiceManagement
import SleepControl

enum SleepServiceRegistration {
    /// Explicit recovery for a registration left pointing at a replaced app.
    /// Wait for removal to finish before registering the current bundle.
    @MainActor static func repair(status: () -> SMAppService.Status,
                                 validate: () throws -> Void,
                                 unregister: () async throws -> Void,
                                 register: () throws -> Void) async throws {
        try validate()
        let current = status()
        guard current != .requiresApproval else {return}
        if current == .enabled {try await unregister()}
        try register()
    }

    /// A missing BTM record can report notFound even with a complete app bundle.
    /// Only explicit enable requests register; approval and enabled states are preserved.
    static func prepare(status: () -> SMAppService.Status,
                        validate: () throws -> Void,
                        register: () throws -> Void) throws -> SMAppService.Status {
        let current = status()
        switch current {
        case .notRegistered, .notFound:
            try validate()
            try register()
            return status()
        default:
            return current
        }
    }

    static func validateBundle(at bundleURL: URL) throws {
        let files = FileManager.default
        let plist = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/" + SleepService.plist)
        let executable = bundleURL.appendingPathComponent("Contents/MacOS/NeuraSleepService")
        guard files.isReadableFile(atPath: plist.path), files.isExecutableFile(atPath: executable.path) else {
            throw SleepSessionError("スリープ制御の同梱ファイルが不足しています。配布版アプリを再インストールしてください。")
        }
    }
}
