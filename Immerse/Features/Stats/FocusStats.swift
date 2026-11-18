import Foundation

/// 专注统计（纯计算，便于测试）
struct FocusStats: Equatable {
    struct Day: Identifiable, Equatable {
        let date: Date
        let minutes: Int
        var id: Date { date }
    }

    struct TaskTotal: Identifiable, Equatable {
        let title: String
        let minutes: Int
        let sessions: Int
        var id: String { title }
    }

    /// 最近 7 天（含今天）每天的专注分钟数，按日期升序
    let lastSevenDays: [Day]
    let todayMinutes: Int
    let weekMinutes: Int
    let weekSessions: Int
    /// 本周完成（含提前完成）的次数
    let weekCompleted: Int
    /// 本周按任务汇总，时长倒序，最多 5 个
    let topTasks: [TaskTotal]
    /// 连续有专注记录的天数（截至今天；今天还没专注时从昨天算起）
    let streakDays: Int

    var weekCompletionRate: Double {
        weekSessions == 0 ? 0 : Double(weekCompleted) / Double(weekSessions)
    }

    /// - Parameter records: 至少覆盖最近 7 天和本周的记录
    init(records: [FocusRecord], now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)

        func minutes(on day: Date) -> Int {
            guard let interval = calendar.dateInterval(of: .day, for: day) else { return 0 }
            return records.reduce(0) { $0 + Self.focusedSeconds($1, within: interval) } / 60
        }

        lastSevenDays = (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { Day(date: $0, minutes: minutes(on: $0)) }
        }
        todayMinutes = minutes(on: today)

        let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: today, duration: 7 * 86400)
        let weekRecords = records.filter { $0.startedAt >= week.start && $0.startedAt < week.end }
        weekMinutes = weekRecords.reduce(0) { $0 + Self.focusedSeconds($1, within: week) } / 60
        weekSessions = weekRecords.count
        weekCompleted = weekRecords.filter { $0.reason != .abandoned }.count

        topTasks = Self.topTasks(weekRecords)

        var streak = 0
        var cursor = minutes(on: today) > 0 ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while minutes(on: cursor) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        streakDays = streak
    }

    private static func topTasks(_ records: [FocusRecord]) -> [TaskTotal] {
        let groups = Dictionary(grouping: records, by: \.taskTitle)
        var totals: [TaskTotal] = []
        for (title, items) in groups {
            let seconds = items.reduce(0) { $0 + $1.focusedSeconds }
            totals.append(TaskTotal(title: title, minutes: seconds / 60, sessions: items.count))
        }
        totals.sort { a, b in a.minutes != b.minutes ? a.minutes > b.minutes : a.title < b.title }
        return Array(totals.prefix(5))
    }

    /// 记录落在 interval 内的专注秒数。暂停时长按比例扣除（记录里只有总暂停时长，不知道具体在哪一段）
    private static func focusedSeconds(_ record: FocusRecord, within interval: DateInterval) -> Int {
        let total = record.endedAt.timeIntervalSince(record.startedAt)
        guard total > 0 else { return 0 }
        let overlapStart = max(record.startedAt, interval.start)
        let overlapEnd = min(record.endedAt, interval.end)
        guard overlapEnd > overlapStart else { return 0 }
        let ratio = overlapEnd.timeIntervalSince(overlapStart) / total
        return Int((Double(record.focusedSeconds) * ratio).rounded())
    }
}
