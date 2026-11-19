import AppKit

/// Observes system wake: timers don't run during sleep, so remaining time must be recomputed immediately on wake
@MainActor
final class PowerMonitor {
    // Only accessed in init / deinit; deinit is nonisolated, hence marked unsafe
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(onWake: @escaping @MainActor @Sendable () -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onWake() }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
