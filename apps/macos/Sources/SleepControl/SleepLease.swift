import Foundation
import Darwin

public enum SleepLease {
    public static func read(path: String, owner: uid_t, token: String, now: Date = Date()) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {return nil}
        defer {close(fd)}
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size < 128,
              abs(now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec)) < 15 else {return nil}
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {return nil}
        let parts = text.split(separator: "\n").map(String.init)
        guard parts.count == 2, parts[0] == token, ["work", "done", "unknown"].contains(parts[1]) else {return nil}
        return parts[1]
    }
}

public struct SleepDebounce {
    private var idleSince: TimeInterval?
    private var unknownSince: TimeInterval?
    public init() {}
    /// Monotonic clock: a wall-clock correction must not prolong a lease.
    public mutating func shouldRelease(state: String, now: TimeInterval) -> Bool {
        switch state {
        case "work": idleSince = nil; unknownSince = nil; return false
        case "done":
            unknownSince = nil
            if idleSince == nil {idleSince = now}
            return now - idleSince! >= 5
        default:
            idleSince = nil
            if unknownSince == nil {unknownSince = now}
            return now - unknownSince! >= 30
        }
    }
}
