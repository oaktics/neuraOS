import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Darwin
import SleepControl

// No network, shell input, or writable privileged installation. The only input
// is a short-lived, user-owned lease containing one of three literal states.
let args = CommandLine.arguments
func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1)
}
guard geteuid() == 0, args.count == 4, let owner = uid_t(args[2]), UUID(uuidString: args[3]) != nil else {fail("Invalid helper invocation")}
let leasePath = args[1], token = args[3]
let root = URL(fileURLWithPath: "/var/run/neuraos-agent-sleep")
func property(_ key: String) -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else {return nil}
    defer {IOObjectRelease(service)}
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}
func pmset(_ arguments: [String]) -> Bool {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    do {try process.run(); process.waitUntilExit(); return process.terminationStatus == 0} catch {return false}
}
func status(_ message: String) {
    let path = root.appendingPathComponent("status")
    try? (token + "\n" + message).write(to: path, atomically: true, encoding: .utf8)
    _ = chmod(path.path, 0o644)
}
func readLease() -> String? {SleepLease.read(path: leasePath, owner: owner, token: token)}
func unsafePower() -> Bool {
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

guard readLease() != nil else {fail("作業状態の有効期限が切れています。再度有効にしてください。")}
guard property("AppleClamshellState") != nil else {fail("蓋の状態を取得できないMacです。")}
// SleepDisabled may be absent when false; never adopt another utility's override.
guard property("SleepDisabled") != true else {fail("別のアプリがスリープを無効にしています。先に解除してください。")}
var active = false
var debounce = SleepDebounce()
func release() -> Bool {
    guard active else {return true}
    guard pmset(["-a", "disablesleep", "0"]) else {return false}
    active = false
    try? FileManager.default.removeItem(at: root.appendingPathComponent("owned"))
    return true
}
while let state = readLease() {
    if unsafePower() {fail("バッテリー残量または温度のため解除しました。") }
    let shouldRelease = debounce.shouldRelease(state: state, now: ProcessInfo.processInfo.systemUptime)
    if state == "work" {
        if !active {
            guard property("SleepDisabled") != true else {fail("別のアプリがスリープを無効にしました。先に解除してください。")}
            // Marker precedes mutation so the supervisor can always restore.
            do {try Data().write(to: root.appendingPathComponent("owned"))} catch {fail("Cannot create recovery marker")}
            guard pmset(["-a", "disablesleep", "1"]) else {fail("閉蓋スリープを抑制できませんでした。")}
            active = true
        }
        // Reapply if power-source changes reset the system setting.
        if property("SleepDisabled") != true {
            guard pmset(["-a", "disablesleep", "1"]), property("SleepDisabled") == true else {fail("macOSが閉蓋スリープの抑制を受け付けませんでした。")}
        }
        status("作業中：蓋を閉じても継続します")
    } else if state == "done" {
        if active && shouldRelease {
            let closed = property("AppleClamshellState") == true
            guard release() else {fail("スリープ設定の復元に失敗しました。")}
            if closed {guard pmset(["sleepnow"]) else {fail("スリープ要求に失敗しました。")}}
        }
        status(active ? "作業終了を確認中…" : "待機中：通常のスリープ設定")
    } else {
        if active && shouldRelease {
            guard release() else {fail("スリープ設定の復元に失敗しました。")}
        }
        status(active ? "作業状態を確認できません（30秒で抑制解除）" : "作業状態不明：抑制していません")
    }
    Thread.sleep(forTimeInterval: 1)
}
if !release() {fail("スリープ設定の復元に失敗しました。")}
