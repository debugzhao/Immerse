#if DEBUG
import AppKit
import Foundation

/// IMMERSE_PROFILE_SWITCH=<output file>: switch day / week / month a few times and record how long the main thread
/// was blocked after each switch (a background thread pings the main queue every 5 ms). Dev-only diagnostics.
@MainActor
enum SwitchProfiler {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var maxStall: TimeInterval = 0
        private var running = true

        func start() {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let sent = CACurrentMediaTime()
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { done.signal() }
                    done.wait()
                    let stall = CACurrentMediaTime() - sent
                    lock.withLock { maxStall = max(maxStall, stall) }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }

        func reset() -> TimeInterval { lock.withLock { defer { maxStall = 0 }; return maxStall } }
        func stop() { lock.withLock { running = false } }
    }

    private static func capture(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func runIfRequested(environment: AppEnvironment) {
        guard let output = ProcessInfo.processInfo.environment["IMMERSE_PROFILE_SWITCH"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let probe = Probe()
            probe.start()
            var lines: [String] = []
            // IMMERSE_PROFILE_LOOP=1: keep switching for ~8 s so an external `sample` can catch the hot path
            let loop = ProcessInfo.processInfo.environment["IMMERSE_PROFILE_LOOP"] != nil
            let modes: [CalendarMode] = loop ? Array(repeating: [.month, .week, .day], count: 9).flatMap { $0 }
                                             : [.month, .week, .day, .week, .month, .day]
            for mode in modes {
                if loop {
                    environment.calendarStore.mode = mode
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                _ = probe.reset()
                let start = CACurrentMediaTime()
                environment.calendarStore.mode = mode
                // IMMERSE_PROFILE_FRAMES=<dir>: grab frames shortly after the switch to check the first frames
                if let dir = ProcessInfo.processInfo.environment["IMMERSE_PROFILE_FRAMES"] {
                    for ms in [40, 150] {
                        try? await Task.sleep(for: .milliseconds(ms == 40 ? 40 : 110))
                        capture(to: "\(dir)/\(lines.count)-\(mode.rawValue)-\(ms)ms.png")
                    }
                }
                try? await Task.sleep(for: .milliseconds(1200))
                lines.append(String(format: "→ %@  max main-thread stall %.0f ms  (t=%.0f ms)", mode.rawValue, probe.reset() * 1000,
                                    (CACurrentMediaTime() - start) * 1000))
            }
            probe.stop()
            try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
#endif
