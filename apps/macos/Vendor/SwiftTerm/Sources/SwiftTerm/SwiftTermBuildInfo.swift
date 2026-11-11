// Upstream generates this file from Git with a build-tool plugin. The vendored
// copy pins the values that plugin produced for the v1.20.0 checkout, so the
// XTVERSION reply programs see ("SwiftTerm 1.20.0+v1.20.0") is unchanged.
// Local changes are listed in ../../VENDORED.md.

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    /// The Git branch, if the build uses a branch checkout.
    public static let branch: String? = nil

    /// The exact Git tag of the upstream commit this copy is based on.
    public static let tag: String? = "v1.20.0"

    /// The full upstream Git commit identifier this copy is based on.
    public static let commit: String? = "5d14406844143538cd8f8851d2d8a67c1fe443e5"

    /// Kept `false` so `version` and the XTVERSION reply match upstream v1.20.0.
    public static let hasUncommittedChanges: Bool? = false

    /// A value suitable for display in logs and diagnostic output.
    public static let version: String = {
        let base = tag ?? commit.map { String($0.prefix(12)) } ?? "unknown"
        return hasUncommittedChanges == true ? "\(base)-modified" : base
    }()
}
