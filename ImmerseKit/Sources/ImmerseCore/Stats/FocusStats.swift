import Foundation

/// Focus statistics (pure computation, easy to test)
public struct FocusStats: Equatable {
    public struct Day: Identifiable, Equatable {
        public let date: Date
        public let minutes: Int
        public var id: Date { date }
    }

    public struct TaskTotal: Identifiable, Equatable {
        public let title: String
        public let minutes: Int
        public let sessions: Int
        public var id: String { title }
    }

    /// Focus minutes per day for the last 7 days (including today), ascending by date
    public let lastSevenDays: [Day]
    public let todayMinutes: Int
    public let weekMinutes: Int
    public let weekSessions: Int
    /// Completions this week (including early completions)
    public let weekCompleted: Int
    /// This week's totals per task, descending by duration, at most 5
    public let topTasks: [TaskTotal]
    /// Consecutive days with focus records (up to today; if no focus yet today, counted from yesterday)
    public let streakDays: Int

    public var weekCompletionRate: Double {
        weekSessions == 0 ? 0 : Double(weekCompleted) / Double(weekSessions)
    }

    /// - Parameter records: records covering at least the last 7 days and this week
    public init(records: [FocusRecord], now: Date, calendar: Calendar) {
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

    /// Focus seconds of a record that fall within interval. Pause time is deducted proportionally (the record only has total pause duration, not which segments were paused)
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
