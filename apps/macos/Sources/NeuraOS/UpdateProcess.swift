import Foundation
import Darwin

enum UpdateProcess {
    // Run off the main actor. Preparation owns its deadlines in JavaScript so
    // errors can release its install lock before returning to the UI.
    static func run(executable: String, arguments: [String], timeout: TimeInterval?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        // File-backed output avoids pipe deadlocks during a long download.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {try? FileManager.default.removeItem(at: log)}
        let handle = try FileHandle(forWritingTo: log)
        defer {try? handle.close()}
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let clock = ContinuousClock()
        let deadline = timeout.map {clock.now.advanced(by: .seconds($0))}
        while process.isRunning {
            if let deadline, clock.now >= deadline {
                process.terminate()
                let grace = clock.now.advanced(by: .seconds(2))
                while process.isRunning && clock.now < grace {Thread.sleep(forTimeInterval: 0.05)}
                if process.isRunning {kill(process.processIdentifier, SIGKILL)}
                while process.isRunning {Thread.sleep(forTimeInterval: 0.05)}
                throw NSError(domain: "neuraOS.Update", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "更新処理が時間内に完了しませんでした。ネット接続を確認して再度お試しください。"])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let data = try Data(contentsOf: log)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "neuraOS.Update", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(data: data, encoding: .utf8) ?? "更新に失敗しました。"])
        }
        return data
    }
}
