import Foundation
import ImmerseCore

/// How much is booked on a day against how much the user actually gets done
public struct DayLoad: Equatable, Sendable {
    public var day: Date
    public var plannedMinutes: Int
    public var capacityMinutes: Int
    /// false while there are too few focus days to know the user's own capacity
    public var capacityIsPersonal: Bool

    public var overloadMinutes: Int { max(plannedMinutes - capacityMinutes, 0) }
    public var isOverloaded: Bool { overloadMinutes >= 30 }
}

public enum LoadEstimator {
    /// Used until there are `minimumDays` days of focus history
    public static let defaultCapacityMinutes = 360
    public static let minimumDays = 5

    /// P75 of daily focused minutes over the last 14 days (days with any focus only), excluding today
    public static func capacity(records: [FocusRecord], now: Date, calendar: Calendar) -> (minutes: Int, isPersonal: Bool) {
        let today = calendar.startOfDay(for: now)
        guard let since = calendar.date(byAdding: .day, value: -14, to: today) else { return (defaultCapacityMinutes, false) }
        var perDay: [Date: Int] = [:]
        for record in records where record.startedAt >= since && record.startedAt < today && record.reason != .abandoned {
            perDay[calendar.startOfDay(for: record.startedAt), default: 0] += record.focusedSeconds / 60
        }
        let days = perDay.values.filter { $0 > 0 }.sorted()
        guard days.count >= minimumDays else { return (defaultCapacityMinutes, false) }
        let index = min(Int((Double(days.count - 1) * 0.75).rounded()), days.count - 1)
        return (max(days[index], 60), true)
    }

    public static func load(on day: Date, context: PlanningContext) -> DayLoad {
        let calendar = context.calendar
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let planned = context.tasks
            .filter { $0.kind == .event && !$0.isAllDay && $0.status != .done }
            .filter { $0.displayInterval(in: calendar).overlapsHalfOpen(DateInterval(start: start, end: end)) }
            .reduce(0) { $0 + context.estimatedMinutes(for: $1) }
        let capacity = capacity(records: context.records, now: context.now, calendar: calendar)
        return DayLoad(day: start, plannedMinutes: planned, capacityMinutes: capacity.minutes,
                       capacityIsPersonal: capacity.isPersonal)
    }

    /// Events to move off an overloaded day: not started yet, movable, least important and latest first
    public static func deferrals(for load: DayLoad, context: PlanningContext) -> [TaskSnapshot] {
        guard load.isOverloaded else { return [] }
        let calendar = context.calendar
        let end = calendar.date(byAdding: .day, value: 1, to: load.day) ?? load.day
        let candidates = context.tasks
            .filter { Reflow.isMovable($0) && $0.start >= context.now && $0.start >= load.day && $0.start < end }
            .sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.start > b.start }
        var freed = 0
        var result: [TaskSnapshot] = []
        for task in candidates where freed < load.overloadMinutes {
            result.append(task)
            freed += context.estimatedMinutes(for: task)
        }
        return result
    }
}

/// A task likely to miss its deadline
public struct DeadlineRiskItem: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        /// It sits on the calendar after its deadline
        case scheduledTooLate
        /// Not scheduled, and the free time before the deadline is too short
        case notEnoughTime
        /// The deadline has passed and it isn't done
        case overdue
    }

    public var task: TaskSnapshot
    public var kind: Kind
    public var requiredMinutes: Int
    public var availableMinutes: Int
    /// Rough days late if nothing changes
    public var delayDays: Int
    public var id: UUID { task.id }
}

public enum DeadlineRisk {
    /// Only this share of free time is counted as usable (meetings run over, life happens)
    public static let usableShare = 0.8

    public static func assess(context: PlanningContext) -> [DeadlineRiskItem] {
        let calendar = context.calendar
        return context.tasks.compactMap { task -> DeadlineRiskItem? in
            guard let deadline = task.deadline, task.status != .done, task.kind != .goal else { return nil }
            let required = max(context.estimatedMinutes(for: task) - context.focusedMinutes(on: task.id), 0)
            if deadline <= context.now {
                let days = max(calendar.dateComponents([.day], from: deadline, to: context.now).day ?? 0, 1)
                return DeadlineRiskItem(task: task, kind: .overdue, requiredMinutes: required, availableMinutes: 0, delayDays: days)
            }
            if task.kind == .event {
                let end = task.displayInterval(in: calendar).end
                guard end > deadline else { return nil }
                let days = max(Int((end.timeIntervalSince(deadline) / 86400).rounded(.up)), 1)
                return DeadlineRiskItem(task: task, kind: .scheduledTooLate, requiredMinutes: required,
                                        availableMinutes: 0, delayDays: days)
            }
            // Unscheduled: compare against free time between now and the deadline
            let slots = SlotFinder.freeSlots(in: DateInterval(start: context.now, end: deadline), context: context)
            let available = Int(Double(slots.reduce(0) { $0 + $1.minutes }) * usableShare)
            guard required > available else { return nil }
            let perDay = max(available / max(calendar.dateComponents([.day], from: context.now, to: deadline).day ?? 1, 1), 60)
            let days = max(Int((Double(required - available) / Double(perDay)).rounded(.up)), 1)
            return DeadlineRiskItem(task: task, kind: .notEnoughTime, requiredMinutes: required,
                                    availableMinutes: available, delayDays: days)
        }
        .sorted { ($0.task.deadline ?? .distantFuture) < ($1.task.deadline ?? .distantFuture) }
    }
}

/// "Reading tasks take you 60% longer than planned"
public struct CalibrationInsight: Equatable, Identifiable, Sendable {
    public var category: TaskCategory
    /// Median of actual / planned
    public var ratio: Double
    public var samples: Int
    public var id: TaskCategory { category }

    /// Rounded to 0.1 for display and for the stored multiplier
    public var suggestedMultiplier: Double { (ratio * 10).rounded() / 10 }

    public var message: String {
        let percent = Int((abs(ratio - 1) * 100).rounded())
        return ratio > 1
            ? "\(category.title)类任务平均超时 \(percent)%，以后默认按 \(String(format: "%.1f", suggestedMultiplier)) 倍预估？"
            : "\(category.title)类任务平均提前 \(percent)% 完成，以后默认按 \(String(format: "%.1f", suggestedMultiplier)) 倍预估？"
    }
}

public enum Calibration {
    public static let minimumSamples = 5
    /// Only suggest a change when estimates are off by more than this
    public static let threshold = 0.25

    /// Per category: median of (focused time / planned time) over finished tasks that were focused on
    public static func ratios(tasks: [TaskSnapshot], records: [FocusRecord]) -> [TaskCategory: (ratio: Double, samples: Int)] {
        var focused: [UUID: Int] = [:]
        for record in records where record.reason != .abandoned {
            if let id = record.taskID { focused[id, default: 0] += record.focusedSeconds }
        }
        var perCategory: [TaskCategory: [Double]] = [:]
        for task in tasks where task.status == .done && task.kind == .event {
            guard let category = task.category, let seconds = focused[task.id], seconds > 0 else { continue }
            let planned = Double(task.focusMinutes * 60)
            guard planned > 0 else { continue }
            perCategory[category, default: []].append(Double(seconds) / planned)
        }
        return perCategory.mapValues { values in
            let sorted = values.sorted()
            let middle = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            return (median, values.count)
        }
    }

    public static func insights(tasks: [TaskSnapshot], records: [FocusRecord],
                                accepted: [TaskCategory: Double] = [:]) -> [CalibrationInsight] {
        ratios(tasks: tasks, records: records).compactMap { category, value in
            guard value.samples >= minimumSamples, abs(value.ratio - 1) > threshold else { return nil }
            let insight = CalibrationInsight(category: category, ratio: value.ratio, samples: value.samples)
            // Already accepted (close enough): don't nag again
            if let current = accepted[category], abs(current - insight.suggestedMultiplier) < 0.15 { return nil }
            return insight
        }
        .sorted { abs($0.ratio - 1) > abs($1.ratio - 1) }
    }

    /// Setting key for a category's accepted multiplier
    public static func settingKey(_ category: TaskCategory) -> String { "estimate.\(category.rawValue)" }
}

/// How often to work on a goal to finish it in time: "每周 3 次 × 50 分钟"
public struct GoalCadence: Equatable, Sendable {
    public var remainingMinutes: Int
    public var weeks: Int
    public var sessionsPerWeek: Int
    public var minutesPerSession: Int

    public var summary: String { "每周 \(sessionsPerWeek) 次 × \(minutesPerSession) 分钟" }
}

public enum GoalBreakdown {
    public static func cadence(targetMinutes: Int, focusedMinutes: Int, now: Date, periodEnd: Date, calendar: Calendar) -> GoalCadence? {
        let remaining = targetMinutes - focusedMinutes
        guard remaining > 0, periodEnd > now else { return nil }
        let days = max(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: periodEnd).day ?? 1, 1)
        let weeks = max(Int((Double(days) / 7).rounded(.up)), 1)
        let perWeek = Double(remaining) / Double(weeks)
        var sessions = max(Int((perWeek / 60).rounded(.up)), 1)
        // Keep sessions long enough to get into it, short enough to start
        var length = Int((perWeek / Double(sessions) / 5).rounded(.up)) * 5
        if length < 25 && sessions > 1 {
            sessions = max(Int(perWeek / 25), 1)
            length = Int((perWeek / Double(sessions) / 5).rounded(.up)) * 5
        }
        sessions = min(sessions, days)
        return GoalCadence(remainingMinutes: remaining, weeks: weeks, sessionsPerWeek: sessions,
                           minutesPerSession: min(max(length, 25), Scheduler.maxBlockMinutes))
    }

    /// Books the cadence into the highest-energy free slots, one session per day, for the rest of the period
    public static func plan(goal: TaskSnapshot, cadence: GoalCadence, context: PlanningContext) -> PlanProposal? {
        let calendar = context.calendar
        let period = goal.displayInterval(in: calendar)
        var items: [PlanProposal.Item] = []
        var weekStart = calendar.startOfDay(for: max(context.now, period.start))
        while weekStart < period.end {
            let weekEnd = min(calendar.date(byAdding: .day, value: 7, to: weekStart) ?? period.end, period.end)
            let slots = SlotFinder.freeSlots(in: DateInterval(start: weekStart, end: weekEnd), context: context,
                                             minimumMinutes: cadence.minutesPerSession)
            var usedDays: Set<Date> = []
            for slot in slots.sorted(by: { $0.energy > $1.energy }) where usedDays.count < cadence.sessionsPerWeek {
                let day = calendar.startOfDay(for: slot.interval.start)
                guard !usedDays.contains(day) else { continue }
                usedDays.insert(day)
                let end = slot.interval.start.addingTimeInterval(TimeInterval(cadence.minutesPerSession * 60))
                items.append(PlanProposal.Item(
                    operation: .create(TaskSnapshot(title: goal.title, start: slot.interval.start, end: end, isAllDay: false,
                                                    priority: goal.priority, plannedMinutes: cadence.minutesPerSession,
                                                    kind: .event, goalID: goal.id, category: goal.category, source: .agent)),
                    reason: "\(cadence.summary)，挑了这周精力较好的时段"))
            }
            weekStart = weekEnd
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.operation.sortDate < $1.operation.sortDate }
        return PlanProposal(origin: .goal, summary: "为「\(goal.displayTitle)」安排 \(items.count) 次专注（\(cadence.summary)）",
                            items: items, createdAt: context.now)
    }
}

extension PlanProposal.Operation {
    public var sortDate: Date {
        switch self {
        case .create(let task), .update(let task): task.start
        case .move(_, let start, _): start
        case .toInbox: .distantFuture
        }
    }
}

/// What to know before starting a session: where you left off and what's still open
public struct FocusBriefing: Equatable, Sendable {
    public var lastSession: FocusRecord?
    /// Unchecked `- [ ]` items from the notes
    public var openTodos: [String]
    /// From calibration, e.g. "这类任务你通常会超时 30%"
    public var estimateNote: String?

    public var isEmpty: Bool { lastSession == nil && openTodos.isEmpty && estimateNote == nil }
}

public enum Briefing {
    public static func openTodos(in notes: String) -> [String] {
        notes.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [ ] ", "* [ ] ", "[] ", "- [] "] where trimmed.hasPrefix(prefix) {
                let item = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return item.isEmpty ? nil : item
            }
            return nil
        }
    }

    public static func beforeFocus(on task: TaskSnapshot, context: PlanningContext) -> FocusBriefing {
        let last = context.records.filter { $0.taskID == task.id }.max { $0.endedAt < $1.endedAt }
        var note: String?
        if let category = task.category,
           let ratio = Calibration.ratios(tasks: context.tasks, records: context.records)[category],
           ratio.samples >= Calibration.minimumSamples, abs(ratio.ratio - 1) > Calibration.threshold {
            let percent = Int((abs(ratio.ratio - 1) * 100).rounded())
            note = ratio.ratio > 1 ? "这类任务你通常会超时 \(percent)%" : "这类任务你通常会提前 \(percent)% 完成"
        }
        return FocusBriefing(lastSession: last, openTodos: openTodos(in: task.notes), estimateNote: note)
    }
}

/// Keyword rules used when the AI is off: good enough for the common cases, never blocks capture
public enum CategoryGuesser {
    static let rules: [(TaskCategory, [String])] = [
        (.meeting, ["会", "开会", "周会", "例会", "评审", "面试", "聊", "沟通", "对齐", "同步", "1:1", "约"]),
        (.reading, ["读", "阅读", "看书", "书", "论文", "文章"]),
        (.writing, ["写", "文档", "报告", "方案", "总结", "周报", "稿", "博客"]),
        (.exercise, ["健身", "跑步", "运动", "瑜伽", "游泳", "打球", "球", "骑行", "徒步"]),
        (.learning, ["学", "课", "练习", "复习", "背单词", "教程"]),
        (.admin, ["回复", "邮件", "报销", "缴费", "整理", "打电话", "预约", "填表", "提交"]),
        (.deepWork, ["开发", "编码", "代码", "设计", "重构", "调研", "分析", "研究", "debug", "实现"]),
        (.life, ["买", "取", "做饭", "打扫", "洗", "看医生", "家", "接", "送"]),
    ]

    public static func guess(_ title: String) -> TaskCategory? {
        let lower = title.lowercased()
        return rules.first { _, keywords in keywords.contains { lower.contains($0) } }?.0
    }

    /// Titles that read like a project rather than one sitting: "写年终总结", "准备季度汇报"
    public static func looksLarge(_ title: String, minutes: Int?) -> Bool {
        if let minutes, minutes >= 180 { return true }
        let verbs = ["写", "做", "准备", "整理", "完成", "搭建", "重构", "设计"]
        let objects = ["报告", "方案", "总结", "汇报", "论文", "项目", "系统", "计划", "PPT", "ppt"]
        return verbs.contains { title.contains($0) } && objects.contains { title.contains($0) }
    }
}
