import Foundation

/// Value-type snapshot of a task.
///
/// Layers above the data layer (stores, views) only touch this type and never hold SwiftData `@Model` objects directly:
/// first, views avoid managed-object lifecycle problems; second, swapping storage later (iCloud / Notion sync) needs no upper-layer changes.
struct TaskSnapshot: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var start: Date
    /// All-day task: last day (inclusive); timed task: end time. nil means start time only.
    var end: Date?
    var isAllDay: Bool
    var priority: Priority = .normal
    var status: TaskStatus = .todo
    var notes: String = ""
    var place: String?
    /// Planned focus duration (minutes); derived from the date range when nil.
    var plannedMinutes: Int?

    /// Fallback focus duration for all-day tasks or tasks with only a start time.
    static let defaultFocusMinutes = 60
    /// Minimum length drawn on the calendar for a timed task with only a start time.
    static let defaultDisplayMinutes = 30

    /// Half-open interval [start, end) occupied on the calendar. An all-day task spans from midnight of the first day to midnight after the last day.
    func displayInterval(in calendar: Calendar) -> DateInterval {
        if isAllDay {
            let first = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: max(end ?? start, start))
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            return DateInterval(start: first, end: endExclusive)
        }
        let fallback = start.addingTimeInterval(TimeInterval((plannedMinutes ?? Self.defaultDisplayMinutes) * 60))
        return DateInterval(start: start, end: max(end ?? fallback, start))
    }

    /// Duration used when tapping "Start Focus": explicit setting > date range > default 60 minutes.
    var focusMinutes: Int {
        if let plannedMinutes, plannedMinutes > 0 { return plannedMinutes }
        if !isAllDay, let end, end > start {
            return Int(end.timeIntervalSince(start) / 60)
        }
        return Self.defaultFocusMinutes
    }
}

extension DateInterval {
    /// Half-open interval overlap check: touching endpoints don't count as overlap; a zero-length interval inside `other` does.
    func overlapsHalfOpen(_ other: DateInterval) -> Bool {
        if duration == 0 {
            return start >= other.start && start < other.end
        }
        return start < other.end && end > other.start
    }
}
