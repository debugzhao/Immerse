import Foundation
import ImmerseCore

/// An event from the system calendar (EventKit). Read-only: the secretary schedules around it but never edits it.
public struct ExternalEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarTitle: String

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, calendarTitle: String = "") {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
    }
}

/// Where external events come from. The iOS app implements it with EventKit; tests and macOS pass a fixed list.
@MainActor
public protocol ExternalCalendarSource: AnyObject {
    var isAuthorized: Bool { get }
    func events(in interval: DateInterval) -> [ExternalEvent]
}

/// The hours the secretary may book. Gaps outside them are never offered.
public struct Workday: Equatable, Sendable {
    public var startHour: Int
    public var endHour: Int

    public init(startHour: Int = 9, endHour: Int = 22) {
        self.startHour = startHour
        self.endHour = endHour
    }

    public func window(on day: Date, calendar: Calendar) -> DateInterval? {
        let start = calendar.startOfDay(for: day)
        guard let open = calendar.date(byAdding: .hour, value: startHour, to: start),
              let close = calendar.date(byAdding: .hour, value: endHour, to: start), close > open else { return nil }
        return DateInterval(start: open, end: close)
    }
}

/// Everything the engines read, gathered once per request so every number comes from the same snapshot
public struct PlanningContext: Sendable {
    /// All tasks the store knows (events, ideas, goals)
    public var tasks: [TaskSnapshot]
    /// Finished focus sessions, at least the last 28 days
    public var records: [FocusRecord]
    public var externalEvents: [ExternalEvent]
    public var constraints: [MemoryConstraint]
    /// Accepted estimate multipliers per category (from `ProfileSetting`)
    public var multipliers: [TaskCategory: Double]
    public var workday: Workday
    public var now: Date
    public var calendar: Calendar

    public init(tasks: [TaskSnapshot], records: [FocusRecord], externalEvents: [ExternalEvent] = [],
                constraints: [MemoryConstraint] = [], multipliers: [TaskCategory: Double] = [:],
                workday: Workday = Workday(), now: Date, calendar: Calendar) {
        self.tasks = tasks
        self.records = records
        self.externalEvents = externalEvents
        self.constraints = constraints
        self.multipliers = multipliers
        self.workday = workday
        self.now = now
        self.calendar = calendar
    }

    public var energy: EnergyCurve { EnergyCurve.from(records: records, calendar: calendar) }

    /// Minutes a task is expected to take, after the user's accepted calibration for its category
    public func estimatedMinutes(for task: TaskSnapshot) -> Int {
        let base = task.plannedMinutes ?? (task.kind == .event ? task.focusMinutes : 60)
        let multiplier = task.category.flatMap { multipliers[$0] } ?? 1
        return Int((Double(base) * multiplier / 5).rounded(.up)) * 5
    }

    /// Focused minutes already spent on a task (abandoned sessions don't count)
    public func focusedMinutes(on taskID: UUID) -> Int {
        records.filter { $0.taskID == taskID && $0.reason != .abandoned }.reduce(0) { $0 + $1.focusedSeconds } / 60
    }

    /// Timed calendar events that block time: unfinished events, external meetings and memory rules
    public func busyIntervals(in range: DateInterval, excluding excluded: Set<UUID> = []) -> [DateInterval] {
        let events = tasks
            .filter { $0.kind == .event && !$0.isAllDay && $0.status != .done && !excluded.contains($0.id) }
            .map { $0.displayInterval(in: calendar) }
            .filter { $0.overlapsHalfOpen(range) }
        let external = externalEvents.filter { !$0.isAllDay }
            .map { DateInterval(start: $0.start, end: max($0.end, $0.start)) }
            .filter { $0.overlapsHalfOpen(range) }
        let rules = constraints.flatMap { $0.busyIntervals(in: range, calendar: calendar) }
        return (events + external + rules).sorted { $0.start < $1.start }
    }
}
