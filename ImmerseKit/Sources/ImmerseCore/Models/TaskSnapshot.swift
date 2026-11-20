import Foundation

/// Value-type snapshot of a task.
///
/// Layers above the data layer (stores, views) only touch this type and never hold SwiftData `@Model` objects directly:
/// first, views avoid managed-object lifecycle problems; second, swapping storage later (iCloud / Notion sync) needs no upper-layer changes.
public struct TaskSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var start: Date
    /// All-day task: last day (inclusive); timed task: end time. nil means start time only.
    public var end: Date?
    public var isAllDay: Bool
    public var priority: Priority = .normal
    public var status: TaskStatus = .todo
    public var notes: String = ""
    public var place: String?
    /// Planned focus duration (minutes); derived from the date range when nil.
    public var plannedMinutes: Int?
    /// Event / inbox idea / goal. Ideas and goals never show on the time grid
    public var kind: TaskKind = .event
    /// For events: the goal this session works towards (its focus time counts towards the goal)
    public var goalID: UUID?
    /// For goals: planned total focus time in minutes (nil = just count sessions)
    public var targetMinutes: Int?
    /// Manual position in the Inbox / Goals list after the user drags to reorder (nil = default order)
    public var sortOrder: Double?
    /// Hard due date, separate from `end` (when the calendar block ends). Drives deadline back-planning and risk alerts
    public var deadline: Date?
    public var category: TaskCategory?
    public var effort: TaskEffort?
    /// For sub-tasks produced by splitting a large task
    public var parentID: UUID?
    public var source: TaskSource?
    /// The secretary proposal that wrote this task, so a whole proposal can be traced and undone
    public var proposalID: UUID?

    // Spelled out because the synthesized memberwise initializer is internal to the package
    public init(id: UUID = UUID(), title: String, start: Date, end: Date? = nil, isAllDay: Bool,
                priority: Priority = .normal, status: TaskStatus = .todo, notes: String = "", place: String? = nil,
                plannedMinutes: Int? = nil, kind: TaskKind = .event, goalID: UUID? = nil, targetMinutes: Int? = nil,
                sortOrder: Double? = nil, deadline: Date? = nil, category: TaskCategory? = nil,
                effort: TaskEffort? = nil, parentID: UUID? = nil, source: TaskSource? = nil, proposalID: UUID? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.priority = priority
        self.status = status
        self.notes = notes
        self.place = place
        self.plannedMinutes = plannedMinutes
        self.kind = kind
        self.goalID = goalID
        self.targetMinutes = targetMinutes
        self.sortOrder = sortOrder
        self.deadline = deadline
        self.category = category
        self.effort = effort
        self.parentID = parentID
        self.source = source
        self.proposalID = proposalID
    }

    /// Fallback focus duration for all-day tasks or tasks with only a start time.
    public static let defaultFocusMinutes = 60
    /// Minimum length drawn on the calendar for a timed task with only a start time.
    public static let defaultDisplayMinutes = 30

    /// Half-open interval [start, end) occupied on the calendar. An all-day task spans from midnight of the first day to midnight after the last day.
    public func displayInterval(in calendar: Calendar) -> DateInterval {
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
    public var focusMinutes: Int {
        if let plannedMinutes, plannedMinutes > 0 { return plannedMinutes }
        if !isAllDay, let end, end > start {
            return Int(end.timeIntervalSince(start) / 60)
        }
        return Self.defaultFocusMinutes
    }
}

extension DateInterval {
    /// Half-open interval overlap check: touching endpoints don't count as overlap; a zero-length interval inside `other` does.
    public func overlapsHalfOpen(_ other: DateInterval) -> Bool {
        if duration == 0 {
            return start >= other.start && start < other.end
        }
        return start < other.end && end > other.start
    }
}
