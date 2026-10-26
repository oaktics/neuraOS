import Foundation
import Darwin

public enum SleepLease {
    public static func read(path: String, owner: uid_t, token: String, awakeNanoseconds: UInt64? = nil) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {return nil}
        defer {close(fd)}
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size < 128 else {return nil}
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0, let text = String(bytes: bytes.prefix(count), encoding: .utf8) else {return nil}
        let parts = text.split(separator: "\n").map(String.init)
        // Sample after reading: a concurrent atomic replacement may contain a
        // heartbeat newer than the time at which this function was entered.
        let observed = awakeNanoseconds ?? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // Both processes use the same system-wide awake clock. File mtime ages
        // during normal sleep and must not tear down the authorized session.
        guard parts.count == 3, parts[0] == token, ["work", "done", "unknown"].contains(parts[1]),
              let heartbeat = UInt64(parts[2]), heartbeat <= observed,
              observed - heartbeat < 15_000_000_000 else {return nil}
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
