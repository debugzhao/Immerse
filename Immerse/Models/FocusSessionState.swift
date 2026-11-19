import Foundation

/// How a focus session ended
enum FocusEndReason: String, Codable, CaseIterable, Sendable {
    /// Timer ran out naturally; marked complete
    case completed
    /// Finished early, before time was up
    case finishedEarly
    /// Abandoned
    case abandoned

    var title: String {
        switch self {
        case .completed: "完成"
        case .finishedEarly: "提前完成"
        case .abandoned: "放弃"
        }
    }
}

/// A focus session in progress (value type).
///
/// Timing relies only on timestamps, not per-second accumulation: remaining time stays correct after sleep or relaunching a killed app.
///   elapsed = (paused ? pausedAt : now) − startedAt − pausedSeconds
///   remaining = plannedSeconds − elapsed
struct FocusSessionState: Equatable, Sendable {
    var id = UUID()
    let taskID: UUID
    var taskTitle: String
    var startedAt: Date
    var plannedSeconds: Int
    var pausedSeconds: Int = 0
    var pausedAt: Date?

    var isPaused: Bool { pausedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        let reference = pausedAt ?? now
        return max(reference.timeIntervalSince(startedAt) - TimeInterval(pausedSeconds), 0)
    }

    func remaining(at now: Date) -> TimeInterval {
        TimeInterval(plannedSeconds) - elapsed(at: now)
    }

    /// Projected end time from the current state (nil while paused)
    func expectedEnd(at now: Date) -> Date? {
        guard !isPaused else { return nil }
        return now.addingTimeInterval(max(remaining(at: now), 0))
    }

    /// The moment the timer hits zero (paused time already deducted)
    var plannedEnd: Date {
        startedAt.addingTimeInterval(TimeInterval(plannedSeconds + pausedSeconds))
    }

    /// The moment focus progress reaches fraction (0 to 1), projected from the current state; nil while paused
    func moment(atProgress fraction: Double, now: Date) -> Date? {
        guard !isPaused else { return nil }
        return now.addingTimeInterval(TimeInterval(plannedSeconds) * fraction - elapsed(at: now))
    }

    func progress(at now: Date) -> Double {
        guard plannedSeconds > 0 else { return 1 }
        return min(max(elapsed(at: now) / TimeInterval(plannedSeconds), 0), 1)
    }
}

/// A finished focus record, used for stats and the calendar overlay
struct FocusRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: UUID?
    let taskTitle: String
    let startedAt: Date
    let endedAt: Date
    /// Actual focused seconds (excluding pauses)
    let focusedSeconds: Int
    let reason: FocusEndReason

    /// Records worth drawing on the calendar: only those whose event still exists.
    /// Deleting an event nullifies `taskID`, so its focus strips would otherwise linger as orphan bars.
    /// Stats deliberately keep every record, since the time was really spent.
    static func onCalendar(_ records: [FocusRecord], taskExists: (UUID) -> Bool) -> [FocusRecord] {
        records.filter { record in
            guard let taskID = record.taskID else { return false }
            return taskExists(taskID)
        }
    }
}

enum DurationText {
    /// Countdown: "42:17", or "1:02:03" past an hour
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Duration: "1小时25分" or "45分钟"
    static func minutes(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(rest)分"
        }
        return "\(minutes)分钟"
    }
}
