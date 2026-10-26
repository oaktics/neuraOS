import Foundation
import ServiceManagement
import SleepControl

enum SleepServiceRegistration {
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
