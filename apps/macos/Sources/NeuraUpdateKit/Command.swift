import Foundation
import Darwin

public struct CommandResult {
    public let status: Int32
    public let output: String
    public init(status: Int32 = 0, output: String = "") {self.status = status; self.output = output}
}
public struct UpdateFailure: LocalizedError {
    public let message: String
    public init(_ message: String) {self.message = message}
    public var errorDescription: String? {message}
}
public typealias CommandRunner = (String, [String], TimeInterval) throws -> CommandResult

public enum NativeCommand {
    // Every command owns a new process group. On timeout kill and reap the whole
    // group before returning, including launchctl/gh descendants that ignore TERM.
    private static func spawn(_ executable: String, _ arguments: [String], output: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer {posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes)}
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        var argv = ([executable] + arguments).map {strdup($0)} + [nil]
        var env = environment.map {strdup("\($0.key)=\($0.value)")} + [nil]
        defer {argv.forEach {free($0)}; env.forEach {free($0)}}
        var pid: pid_t = 0
        let result = posix_spawnp(&pid, executable, &actions, &attributes, &argv, &env)
        guard result == 0 else {throw UpdateFailure("\(executable): \(String(cString: strerror(result)))")}
        return pid
    }
    public static func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> CommandResult {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("neura-update-\(UUID().uuidString).log")
        defer {try? FileManager.default.removeItem(at: log)}
        let pid = try spawn(executable, arguments, output: log.path)
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {break}
            if result < 0 && errno != EINTR {throw UpdateFailure("Unable to reap update command")}

            if clock.now >= deadline {
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw UpdateFailure("更新コマンドが時間内に完了しませんでした: \(executable)")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let file = try FileHandle(forReadingFrom: log)
        defer {try? file.close()}
        let length = try file.seekToEnd()
        try file.seek(toOffset: length > 65536 ? length - 65536 : 0)
        let bytes = try file.read(upToCount: 65536) ?? Data()
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandResult(status: code, output: String(decoding: bytes.suffix(65536), as: UTF8.self))
    }
    public static func launch(_ executable: String, _ arguments: [String]) throws {
        _ = try spawn(executable, arguments, output: "/dev/null")
    }
}
