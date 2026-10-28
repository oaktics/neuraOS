import Foundation

struct GitHubRefreshPolicy {
    static func interval(state: String?, checks: [String], selected: Bool = true) -> TimeInterval? {
        // Discover externally-created PRs even when the last PR is terminal.
        if selected {return 60}
        if state == "CLOSED" {return 900}
        if state == "MERGED" {
            let terminal = Set(["SUCCESS", "NEUTRAL", "SKIPPED", "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"])
            // A branch can acquire a new PR even after its previous PR merged.
            return checks.allSatisfy {terminal.contains($0)} ? 900 : 60
        }
        return selected ? 60 : state == nil ? 900 : 120
    }
    static func retryDelay(failures: Int) -> TimeInterval {
        min(900, 60 * pow(2, Double(max(0, min(failures - 1, 4)))))
    }
}
