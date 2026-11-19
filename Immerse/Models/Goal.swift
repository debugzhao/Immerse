import Foundation

/// The period a goal covers
enum GoalPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        }
    }

    /// First day (00:00) and last day (00:00, inclusive) of the week / month containing `date`
    func range(containing date: Date, calendar: Calendar) -> (start: Date, lastDay: Date) {
        let component: Calendar.Component = self == .week ? .weekOfYear : .month
        let interval = calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86400)
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        return (interval.start, calendar.startOfDay(for: last))
    }
}

/// Progress of a goal (pure computation, easy to test)
struct GoalProgress: Equatable {
    /// Focus time spent on the goal itself or on events linked to it, within the goal's period
    let focusedMinutes: Int
    let targetMinutes: Int?
    /// Events linked to the goal / how many of them are done
    let scheduledCount: Int
    let completedCount: Int
    /// 0...1 of the period that has passed
    let elapsedFraction: Double
    /// Whole days left including today (0 once the period is over)
    let daysLeft: Int

    /// 0...1. With a target: focus time / target; without: completed / scheduled sessions
    var fraction: Double {
        if let targetMinutes, targetMinutes > 0 {
            return min(Double(focusedMinutes) / Double(targetMinutes), 1)
        }
        return scheduledCount == 0 ? 0 : Double(completedCount) / Double(scheduledCount)
    }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Clearly behind schedule: progress trails elapsed time by more than 15 points (only meaningful with a target)
    var isBehind: Bool {
        targetMinutes != nil && daysLeft > 0 && fraction + 0.15 < elapsedFraction
    }

    init(goal: TaskSnapshot, linkedEvents: [TaskSnapshot], records: [FocusRecord], now: Date, calendar: Calendar) {
        let ids = Set(linkedEvents.map(\.id)).union([goal.id])
        let period = goal.displayInterval(in: calendar)
        focusedMinutes = records
            .filter { record in record.taskID.map(ids.contains) ?? false }
            .reduce(0) { $0 + $1.focusedSeconds } / 60
        targetMinutes = goal.targetMinutes
        scheduledCount = linkedEvents.count
        completedCount = linkedEvents.filter { $0.status == .done }.count
        let elapsed = now.timeIntervalSince(period.start) / max(period.duration, 1)
        elapsedFraction = min(max(elapsed, 0), 1)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: period.end).day ?? 0
        daysLeft = max(days, 0)
    }

    /// "3小时 / 10小时" or "完成 2 / 4 次"
    var summary: String {
        if let targetMinutes {
            return "\(DurationText.minutes(focusedMinutes * 60)) / \(DurationText.minutes(targetMinutes * 60))"
        }
        return scheduledCount == 0 ? "还没安排" : "完成 \(completedCount) / \(scheduledCount) 次"
    }
}

extension TaskSnapshot {
    /// Goals still worth showing: period not over yet
    func isActiveGoal(now: Date, calendar: Calendar) -> Bool {
        kind == .goal && displayInterval(in: calendar).end > now
    }
}
