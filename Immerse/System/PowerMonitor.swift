import AppKit

/// 监听系统唤醒：睡眠期间计时器不跑，唤醒后要立即重新计算剩余时间
@MainActor
final class PowerMonitor {
    // 只在 init / deinit 访问，deinit 是 nonisolated 的，所以标 unsafe
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
