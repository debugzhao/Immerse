import Foundation

/// How a focus session ended
public enum FocusEndReason: String, Codable, CaseIterable, Sendable {
    /// Timer ran out naturally; marked complete
    case completed
    /// Finished early, before time was up
    case finishedEarly
    /// Abandoned
    case abandoned
    /// Time ran out and the user closed the session without marking the task done: the focus time still counts
    case closed

    public var title: String {
        switch self {
        case .completed: "完成"
        case .finishedEarly: "提前完成"
        case .abandoned: "放弃"
        case .closed: "未完成"
        }
    }
}

/// A focus session in progress (value type).
///
/// Timing relies only on timestamps, not per-second accumulation: remaining time stays correct after sleep or relaunching a killed app.
///   elapsed = (paused ? pausedAt : now) − startedAt − pausedSeconds
///   remaining = plannedSeconds − elapsed
public struct FocusSessionState: Equatable, Sendable {
    public var id = UUID()
    public let taskID: UUID
    public var taskTitle: String
    public var startedAt: Date
    public var plannedSeconds: Int
    public var pausedSeconds: Int = 0
    public var pausedAt: Date?

    public var isPaused: Bool { pausedAt != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        let reference = pausedAt ?? now
        return max(reference.timeIntervalSince(startedAt) - TimeInterval(pausedSeconds), 0)
    }

    public func remaining(at now: Date) -> TimeInterval {
        TimeInterval(plannedSeconds) - elapsed(at: now)
    }

    /// Projected end time from the current state (nil while paused)
    public func expectedEnd(at now: Date) -> Date? {
        guard !isPaused else { return nil }
        return now.addingTimeInterval(max(remaining(at: now), 0))
    }

    /// The moment the timer hits zero (paused time already deducted)
    public var plannedEnd: Date {
        startedAt.addingTimeInterval(TimeInterval(plannedSeconds + pausedSeconds))
    }

    /// The moment focus progress reaches fraction (0 to 1), projected from the current state; nil while paused
    public func moment(atProgress fraction: Double, now: Date) -> Date? {
        guard !isPaused else { return nil }
        return now.addingTimeInterval(TimeInterval(plannedSeconds) * fraction - elapsed(at: now))
    }

    public func progress(at now: Date) -> Double {
        guard plannedSeconds > 0 else { return 1 }
        return min(max(elapsed(at: now) / TimeInterval(plannedSeconds), 0), 1)
    }
}

/// A finished focus record, used for stats
public struct FocusRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID?
    public let taskTitle: String
    public let startedAt: Date
    public let endedAt: Date
    /// Actual focused seconds (excluding pauses)
    public let focusedSeconds: Int
    public let reason: FocusEndReason

    public init(id: UUID, taskID: UUID?, taskTitle: String, startedAt: Date, endedAt: Date, focusedSeconds: Int,
                reason: FocusEndReason) {
        self.id = id
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusedSeconds = focusedSeconds
        self.reason = reason
    }
}

public enum DurationText {
    /// Countdown: "42:17", or "1:02:03" past an hour
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Duration: "1小时25分" or "45分钟"
    public static func minutes(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(rest)分"
        }
        return "\(minutes)分钟"
    }
}
