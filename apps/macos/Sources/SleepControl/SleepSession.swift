import Foundation

public protocol SleepPower: AnyObject {
    var sleepDisabled: Bool {get}
    var lidClosed: Bool? {get}
    var unsafePower: Bool {get}
    func acquire() throws
    func release() throws
    func sleepNow() throws
}

/// No privileged execution in the policy: production supplies fixed power
/// operations, tests exercise restoration and errors without touching the Mac.
public final class SleepSession {
    private let power: SleepPower
    private var active = false
    private var debounce = SleepDebounce()
    public init(power: SleepPower) throws {
        guard power.lidClosed != nil else {throw SleepSessionError("蓋の状態を取得できないMacです。")}
        guard !power.sleepDisabled else {throw SleepSessionError("別のアプリがスリープを無効にしています。先に解除してください。")}
        self.power = power
    }
    public func step(state: String, now: TimeInterval) throws -> String {
        guard !power.unsafePower else {throw SleepSessionError("バッテリー残量または温度のため解除しました。")}
        let shouldRelease = debounce.shouldRelease(state: state, now: now)
        if state == "work" {
            if !active {
                guard !power.sleepDisabled else {throw SleepSessionError("別のアプリがスリープを無効にしました。先に解除してください。")}
                // Track ownership before mutation so an error also restores it.
                active = true
                try power.acquire()
            }
            if !power.sleepDisabled {try power.acquire()}
            guard power.sleepDisabled else {throw SleepSessionError("macOSが閉蓋スリープの抑制を受け付けませんでした。")}
            return "作業中：蓋を閉じても継続します"
        }
        if active && shouldRelease {
            let shouldSleep = state == "done" && power.lidClosed == true
            try stop()
            if shouldSleep {try power.sleepNow()}
        }
        if state == "done" {return active ? "作業終了を確認中…" : "待機中：通常のスリープ設定"}
        return active ? "作業状態を確認できません（30秒で抑制解除）" : "作業状態不明：抑制していません"
    }
    public func stop() throws {
        guard active else {return}
        try power.release()
        active = false
    }
}

public struct SleepSessionError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) {errorDescription = message}
}
