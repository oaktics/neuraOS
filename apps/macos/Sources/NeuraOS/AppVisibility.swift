import AppKit
import Observation

/// Whether any neuraOS window is on screen. Refresh loops whose only consumer is
/// the visible UI stop while this is false (app hidden, windows minimized, on
/// another Space or fully covered) and run again at once when it becomes true,
/// so what the user sees on return is never older than it is today.
@MainActor @Observable final class AppVisibility {
    static let shared = AppVisibility()
    private(set) var visible = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    // The frontmost app is being used even if its occlusion state were ever stale.
    init(center: NotificationCenter = .default,
         read: @escaping @MainActor () -> Bool = {NSApp.map {$0.isActive || $0.occlusionState.contains(.visible)} ?? true}) {
        // Stay visible until AppKit reports otherwise: an unknown state must not stop refreshes.
        for name in [NSApplication.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {self?.update(read())}
            })
        }
    }
    // Older Observation runtimes notify even for an equal assignment.
    func update(_ value: Bool) {if visible != value {visible = value}}
}
