import Foundation

/// 专注结束的方式
enum FocusEndReason: String, Codable, CaseIterable, Sendable {
    /// 计时自然结束，并标记完成
    case completed
    /// 时间没到，提前完成
    case finishedEarly
    /// 放弃
    case abandoned

    var title: String {
        switch self {
        case .completed: "完成"
        case .finishedEarly: "提前完成"
        case .abandoned: "放弃"
        }
    }
}

/// 正在进行的专注（值类型）。
///
/// 计时只依赖时间戳，不依赖每秒累加：睡眠、App 被杀后重新打开，算出来的剩余时间都是对的。
///   已用时长 = (暂停中 ? pausedAt : now) − startedAt − pausedSeconds
///   剩余时长 = plannedSeconds − 已用时长
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

    /// 按当前状态推算的结束时间（暂停中返回 nil）
    func expectedEnd(at now: Date) -> Date? {
        guard !isPaused else { return nil }
        return now.addingTimeInterval(max(remaining(at: now), 0))
    }

    /// 计时到点的那一刻（暂停时长已扣除）
    var plannedEnd: Date {
        startedAt.addingTimeInterval(TimeInterval(plannedSeconds + pausedSeconds))
    }

    func progress(at now: Date) -> Double {
        guard plannedSeconds > 0 else { return 1 }
        return min(max(elapsed(at: now) / TimeInterval(plannedSeconds), 0), 1)
    }
}

/// 已结束的专注记录，供统计和日历叠加显示
struct FocusRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: UUID?
    let taskTitle: String
    let startedAt: Date
    let endedAt: Date
    /// 实际专注秒数（扣除暂停）
    let focusedSeconds: Int
    let reason: FocusEndReason
}

enum DurationText {
    /// 倒计时：「42:17」，超过一小时「1:02:03」
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// 时长：「1小时25分」「45分钟」
    static func minutes(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes >= 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60)小时" : "\(minutes / 60)小时\(rest)分"
        }
        return "\(minutes)分钟"
    }
}
