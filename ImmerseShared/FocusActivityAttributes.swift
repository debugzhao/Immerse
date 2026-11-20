import ActivityKit
import Foundation

/// The focus countdown on the Lock Screen and in the Dynamic Island.
/// The countdown itself is drawn by the system from `endDate` (`Text(timerInterval:)`), so it stays accurate
/// while the app is suspended; the app only updates the state on pause / resume / extend / end.
struct FocusActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        /// When the countdown reaches zero; meaningless while paused
        var endDate: Date
        /// Set while paused: the time that was left
        var pausedRemaining: TimeInterval?
        var plannedSeconds: Int
        var isTimeUp: Bool

        var isPaused: Bool { pausedRemaining != nil }

        /// 0…1 at `now`
        func progress(at now: Date) -> Double {
            guard plannedSeconds > 0 else { return 0 }
            let remaining = pausedRemaining ?? max(endDate.timeIntervalSince(now), 0)
            return min(max(1 - remaining / Double(plannedSeconds), 0), 1)
        }
    }

    var taskID: UUID
    var taskTitle: String
}
