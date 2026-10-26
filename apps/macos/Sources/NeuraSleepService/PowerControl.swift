import Foundation
import Darwin
import IOKit
import IOKit.ps
import SleepControl

final class PowerControl: SleepPower {
    let root = URL(fileURLWithPath: SleepService.stateDirectory)
    private var lock: Int32 = -1
    private var marker: URL {root.appendingPathComponent("owned")}
    var statusFile: URL {root.appendingPathComponent("status")}

    init() throws {
        if mkdir(root.path, 0o755) != 0 && errno != EEXIST {throw SleepSessionError("復元情報の保存先を作成できません。")}
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
            throw SleepSessionError("復元情報の保存先が安全ではありません。")
        }
        lock = open(root.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, fstat(lock, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else {throw SleepSessionError("別のスリープ制御サービスが動作中です。")}
        // launchd restarts after a crash. Recover only our own durable marker;
        // never adopt another utility's power override.
        try release()
    }
    deinit {if lock >= 0 {close(lock)}}

    func property(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {return nil}
        defer {IOObjectRelease(service)}
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
    var sleepDisabled: Bool {property("SleepDisabled") == true}
    var lidClosed: Bool? {property("AppleClamshellState")}
    var unsafePower: Bool {
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {return true}
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {return false}
        for source in list {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  values[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else {continue}
            if current * 100 / maximum <= 10 {return true}
        }
        return false
    }
    private func pmset(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {throw SleepSessionError("スリープ設定の変更または復元に失敗しました。")}
    }
    func acquire() throws {
        try Data().write(to: marker, options: .atomic)
        try pmset(["-a", "disablesleep", "1"])
    }
    func release() throws {
        if FileManager.default.fileExists(atPath: marker.path) {
            try pmset(["-a", "disablesleep", "0"])
            try FileManager.default.removeItem(at: marker)
        }
        try? FileManager.default.removeItem(at: statusFile)
    }
    func sleepNow() throws {try pmset(["sleepnow"])}
    func status(token: String, message: String) {
        try? (token + "\n" + message).write(to: statusFile, atomically: true, encoding: .utf8)
        _ = chmod(statusFile.path, 0o644)
    }
}
