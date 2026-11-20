import Foundation
import ImmerseCore
import Observation

/// A proactive notification the secretary wants to send
public struct Nudge: Equatable, Identifiable, Sendable {
    /// Lower raw value = more important; kept when the daily budget is tight (design §4)
    public enum Kind: Int, Comparable, Sendable {
        case deadlineRisk = 0
        case review = 1
        case morning = 2
        case overload = 3

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var fireDate: Date
    public var title: String
    public var body: String
    public var isPassive: Bool

    /// One per kind per day, so a refresh replaces rather than duplicates
    public var id: String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: fireDate)
        return "\(kind)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

/// The user's choices for proactive behavior
@MainActor
@Observable
public final class SecretaryPreferences {
    enum Key {
        static let morningEnabled = "secretary.morning.enabled"
        static let morningMinutes = "secretary.morning.minutes"
        static let budget = "secretary.nudgeBudget"
        static let systemFocusQuiet = "secretary.systemFocusQuiet"
    }

    private let defaults: UserDefaults

    public var morningBriefingEnabled: Bool { didSet { defaults.set(morningBriefingEnabled, forKey: Key.morningEnabled) } }
    /// Minutes from midnight, default 8:30
    public var morningBriefingMinutes: Int { didSet { defaults.set(morningBriefingMinutes, forKey: Key.morningMinutes) } }
    /// Proactive notifications per day, evening review included (0–5, default 3)
    public var dailyNudgeBudget: Int { didSet { defaults.set(dailyNudgeBudget, forKey: Key.budget) } }
    /// Set by the Focus Filter: a system Focus mode is on, so hold every nudge
    public var isSystemFocusQuiet: Bool { didSet { defaults.set(isSystemFocusQuiet, forKey: Key.systemFocusQuiet) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        morningBriefingEnabled = defaults.object(forKey: Key.morningEnabled) as? Bool ?? true
        morningBriefingMinutes = defaults.object(forKey: Key.morningMinutes) as? Int ?? 8 * 60 + 30
        dailyNudgeBudget = defaults.object(forKey: Key.budget) as? Int ?? 3
        isSystemFocusQuiet = defaults.bool(forKey: Key.systemFocusQuiet)
    }
}

public enum NudgePlanner {
    /// When the midday alerts (risk, overload) go out if the morning briefing didn't already cover them
    public static let middayHour = 12

    /// Candidate nudges for one day; `reviewScheduled` counts the evening review against the budget
    public static func candidates(for day: Date, context: PlanningContext, insights: SecretaryInsights,
                                  morningMinutes: Int?) -> [Nudge] {
        let calendar = context.calendar
        let dayStart = calendar.startOfDay(for: day)
        var result: [Nudge] = []
        if let morningMinutes, let brief = MorningBrief.make(day: day, context: context, insights: insights) {
            result.append(Nudge(kind: .morning, fireDate: dayStart.addingTimeInterval(TimeInterval(morningMinutes * 60)),
                                title: brief.title, body: brief.body, isPassive: true))
        }
        let midday = calendar.date(byAdding: .hour, value: middayHour, to: dayStart) ?? dayStart
        if let risk = insights.risks.first(where: { $0.kind != .overdue }) {
            let due = risk.task.deadline.map { TimeText.weekday($0, calendar: calendar) } ?? ""
            result.append(Nudge(kind: .deadlineRisk, fireDate: midday,
                                title: "「\(risk.task.displayTitle)」可能赶不上\(due)截止",
                                body: "按现在的安排会晚 \(risk.delayDays) 天，打开看看补救方案", isPassive: false))
        }
        if calendar.isDate(insights.today.day, inSameDayAs: dayStart), insights.today.isOverloaded {
            result.append(Nudge(kind: .overload, fireDate: midday,
                                title: "今天排得有点满",
                                body: "排了 \(DurationText.minutes(insights.today.plannedMinutes * 60))，按你的节奏大约能完成 \(DurationText.minutes(insights.today.capacityMinutes * 60))，要挪走几项吗？",
                                isPassive: true))
        }
        return result
    }

    /// Applies the budget and quiet time: keeps the most important nudges, moves ones that would land during focus
    /// to just after it (same day only), and drops what's already past.
    public static func select(_ candidates: [Nudge], budget: Int, reviewCounts: Bool, quiet: [DateInterval],
                              now: Date, calendar: Calendar) -> [Nudge] {
        let available = max(budget - (reviewCounts ? 1 : 0), 0)
        var kept: [Nudge] = []
        for nudge in candidates.sorted(by: { ($0.kind, $0.fireDate) < ($1.kind, $1.fireDate) }) where kept.count < available {
            var nudge = nudge
            if let block = quiet.first(where: { $0.start <= nudge.fireDate && nudge.fireDate < $0.end }) {
                nudge.fireDate = block.end.addingTimeInterval(60)
                guard calendar.isDate(nudge.fireDate, inSameDayAs: block.start) else { continue }
            }
            guard nudge.fireDate > now else { continue }
            // The morning briefing already mentions risks and overload; a second ping the same day is noise
            if nudge.kind == .overload, kept.contains(where: { $0.kind == .morning }) { continue }
            kept.append(nudge)
        }
        return kept.sorted { $0.fireDate < $1.fireDate }
    }
}

/// The morning briefing text: today's three most important tasks, meetings, and anything at risk
public enum MorningBrief {
    public static func make(day: Date, context: PlanningContext, insights: SecretaryInsights) -> (title: String, body: String)? {
        let calendar = context.calendar
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let interval = DateInterval(start: start, end: end)
        let tasks = context.tasks
            .filter { $0.kind == .event && $0.status != .done && $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
            .sorted { a, b in a.priority != b.priority ? a.priority < b.priority : a.start < b.start }
        let meetings = context.externalEvents.filter { !$0.isAllDay && DateInterval(start: $0.start, end: $0.end).overlapsHalfOpen(interval) }
        guard !tasks.isEmpty || !meetings.isEmpty || !insights.risks.isEmpty || !insights.behindGoals.isEmpty else { return nil }

        let title = tasks.isEmpty ? "早安，今天没有安排任务" : "早安，今天 \(tasks.count) 件事"
        var lines: [String] = []
        if !tasks.isEmpty {
            lines.append("要事：" + tasks.prefix(3).map(\.displayTitle).joined(separator: "、"))
        }
        if !meetings.isEmpty {
            lines.append("\(meetings.count) 个会议，第一个 \(TimeText.hhmm(meetings.map(\.start).min()!, calendar: calendar))")
        }
        let load = LoadEstimator.load(on: day, context: context)
        if load.isOverloaded {
            lines.append("排了 \(DurationText.minutes(load.plannedMinutes * 60))，可能过载")
        }
        if let risk = insights.risks.first {
            lines.append("「\(risk.task.displayTitle)」有延期风险")
        }
        if let goal = insights.behindGoals.first {
            lines.append("目标「\(goal.goal.displayTitle)」进度 \(goal.progress.percent)%，有点落后")
        }
        return (title, lines.joined(separator: "\n"))
    }
}

/// Evening review: what's left today and where it would go tomorrow
public enum EveningReview {
    public struct Summary: Sendable {
        public var done: Int
        public var total: Int
        public var focusedMinutes: Int
        public var interruptions: Int
        public var unfinished: [TaskSnapshot]
    }

    public static func summary(for day: Date, context: PlanningContext) -> Summary {
        let calendar = context.calendar
        let start = calendar.startOfDay(for: day)
        let interval = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        let tasks = context.tasks.filter { $0.kind == .event && $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
        let records = context.records.filter { interval.contains($0.startedAt) }
        return Summary(done: tasks.filter { $0.status == .done }.count, total: tasks.count,
                       focusedMinutes: records.filter { $0.reason != .abandoned }.reduce(0) { $0 + $1.focusedSeconds } / 60,
                       interruptions: records.filter { $0.reason == .abandoned }.count,
                       unfinished: tasks.filter { $0.status != .done && !$0.isAllDay }.sorted { $0.start < $1.start })
    }

    /// Moves the chosen unfinished tasks into tomorrow's best slots; whatever doesn't fit goes back to the Inbox
    public static func carryOver(_ tasks: [TaskSnapshot], from day: Date, context: PlanningContext) -> PlanProposal? {
        let calendar = context.calendar
        guard !tasks.isEmpty,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)),
              let after = calendar.date(byAdding: .day, value: 1, to: tomorrow) else { return nil }
        var tomorrowContext = context
        tomorrowContext.now = max(context.now, tomorrow)
        let slots = SlotFinder.freeSlots(in: DateInterval(start: tomorrow, end: after), context: tomorrowContext,
                                         excluding: Set(tasks.map(\.id)))
        let placed = Scheduler.plan(tasks, into: slots, context: tomorrowContext)
        var items = placed.items.compactMap { item -> PlanProposal.Item? in
            guard case .update(let task) = item.operation else { return item }
            return PlanProposal.Item(operation: .move(id: task.id, start: task.start, end: task.end),
                                     reason: "顺延到明天 \(TimeText.hhmm(task.start, calendar: calendar))")
        }
        items += placed.unplaced.map { PlanProposal.Item(operation: .toInbox(id: $0.id), reason: "明天也排满了，先放回收集箱") }
        guard !items.isEmpty else { return nil }
        return PlanProposal(origin: .review, summary: "把今天没做完的 \(tasks.count) 项顺延到明天", items: items, createdAt: context.now)
    }
}
