import Foundation
import ImmerseCore

/// One captured item, from the AI or the rule parser
public struct CaptureDraft: Equatable, Sendable {
    public var title: String
    public var kind: TaskKind
    public var start: Date?
    public var isAllDay: Bool
    public var minutes: Int?
    public var priority: Priority?
    public var deadline: Date?
    public var category: TaskCategory?
    public var effort: TaskEffort?
    public var place: String?
    public var goalPeriod: GoalPeriod?
    public var isLarge: Bool
    public var subtasks: [String]

    public init(title: String, kind: TaskKind, start: Date? = nil, isAllDay: Bool = false, minutes: Int? = nil,
                priority: Priority? = nil, deadline: Date? = nil, category: TaskCategory? = nil, effort: TaskEffort? = nil,
                place: String? = nil, goalPeriod: GoalPeriod? = nil, isLarge: Bool = false, subtasks: [String] = []) {
        self.title = title
        self.kind = kind
        self.start = start
        self.isAllDay = isAllDay
        self.minutes = minutes
        self.priority = priority
        self.deadline = deadline
        self.category = category
        self.effort = effort
        self.place = place
        self.goalPeriod = goalPeriod
        self.isLarge = isLarge
        self.subtasks = subtasks
    }

    /// The task this draft becomes. Events without a start fall back to `fallbackStart`.
    public func snapshot(fallbackStart: Date, source: TaskSource, calendar: Calendar) -> TaskSnapshot {
        let start = start ?? fallbackStart
        let begin = isAllDay ? calendar.startOfDay(for: start) : start
        let end: Date? = kind == .event && !isAllDay ? begin.addingTimeInterval(TimeInterval((minutes ?? 60) * 60)) : nil
        return TaskSnapshot(title: title, start: kind == .idea ? fallbackStart : begin, end: end, isAllDay: kind == .event && isAllDay,
                            priority: priority ?? .normal, place: place, plannedMinutes: minutes, kind: kind,
                            deadline: deadline, category: category, effort: effort, source: source)
    }
}

/// Single-shot structured calls (no tools): capture parsing, task splitting, memory parsing and short texts
public enum StructuredCalls {
    // MARK: Capture

    static let captureSchema: JSONValue = {
        let item = Schema.object([
            "title": Schema.string("简洁的中文标题"),
            "kind": Schema.enumeration(["event", "idea", "goal"], description: "event = 有具体时间；idea = 收集箱；goal = 本周/本月目标"),
            "start": Schema.nullable(Schema.string("ISO 8601 with offset", format: "date-time")),
            "all_day": Schema.boolean("只有日期、没有具体时间"),
            "minutes": Schema.nullable(Schema.integer("预计分钟数")),
            "priority": Schema.nullable(Schema.enumeration(["urgent", "important", "normal"], description: "优先级")),
            "deadline": Schema.nullable(Schema.string("ISO 8601 with offset", format: "date-time")),
            "category": Schema.nullable(Schema.enumeration(TaskCategory.allCases.map(\.rawValue), description: "分类")),
            "effort": Schema.nullable(Schema.enumeration(["light", "medium", "hard"], description: "难度")),
            "place": Schema.nullable(Schema.string("地点")),
            "goal_period": Schema.nullable(Schema.enumeration(["week", "month"], description: "目标周期，仅 kind = goal")),
            "is_large": Schema.boolean("是否是需要拆分的大任务"),
            "subtasks": Schema.array(Schema.string("子任务标题"), description: "is_large 时的 2–6 个子任务，否则为空"),
        ])
        return Schema.object(["items": Schema.array(item, description: "一句话里的每件事")])
    }()

    public static func capture(_ text: String, provider: LLMProvider, now: Date, calendar: Calendar) async throws -> (drafts: [CaptureDraft], usage: LLMUsage) {
        let message = """
        现在是 \(DateText.iso(now, calendar: calendar))（\(TimeText.weekday(now, calendar: calendar))），时区 \(calendar.timeZone.identifier)。
        用户说：\(text)
        """
        let response = try await provider.send(LLMRequest(system: Prompts.capture, messages: [["role": "user", "content": .string(message)]],
                                                          effort: "low", maxTokens: 4000, outputSchema: captureSchema))
        try check(response)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(response.text.utf8))
        let drafts = (json["items"]?.array ?? []).compactMap { item -> CaptureDraft? in
            guard let title = item["title"]?.string?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            return CaptureDraft(
                title: title,
                kind: TaskKind(rawValue: item["kind"]?.string ?? "") ?? .idea,
                start: item["start"]?.string.flatMap { try? DateText.parse($0) },
                isAllDay: item["all_day"]?.bool ?? false,
                minutes: item["minutes"]?.int.flatMap { $0 > 0 ? min($0, 720) : nil },
                priority: priority(item["priority"]?.string),
                deadline: item["deadline"]?.string.flatMap { try? DateText.parse($0) },
                category: item["category"]?.string.flatMap(TaskCategory.init(rawValue:)),
                effort: effort(item["effort"]?.string),
                place: item["place"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                goalPeriod: item["goal_period"]?.string.flatMap(GoalPeriod.init(rawValue:)),
                isLarge: item["is_large"]?.bool ?? false,
                subtasks: (item["subtasks"]?.array ?? []).compactMap(\.string))
        }
        return (drafts, response.usage)
    }

    /// The rule-based capture used when the AI is off or fails: one item, keyword category
    public static func ruleCapture(_ text: String, now: Date, calendar: Calendar) -> CaptureDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let goal = PlanningInput.goal(from: trimmed) {
            return CaptureDraft(title: goal.title, kind: .goal, category: CategoryGuesser.guess(goal.title), goalPeriod: goal.period)
        }
        if PlanningInput.isExplicitIdea(trimmed) {
            let title = PlanningInput.idea(from: trimmed)
            return CaptureDraft(title: title, kind: .idea, category: CategoryGuesser.guess(title),
                                isLarge: CategoryGuesser.looksLarge(title, minutes: nil))
        }
        let parsed = NaturalLanguageParser.parse(trimmed, now: now, calendar: calendar)
        let snapshot = parsed.makeSnapshot(now: now, calendar: calendar)
        // No date or time words at all: it's an idea, not an event at "now"
        let hasTime = parsed.date != nil || parsed.start != nil
        return CaptureDraft(title: snapshot.title, kind: hasTime ? .event : .idea, start: hasTime ? snapshot.start : nil,
                            isAllDay: hasTime && snapshot.isAllDay, minutes: parsed.durationMinutes, priority: parsed.priority,
                            category: CategoryGuesser.guess(snapshot.title), place: parsed.place,
                            isLarge: CategoryGuesser.looksLarge(snapshot.title, minutes: parsed.durationMinutes))
    }

    // MARK: Split

    public struct Subtask: Equatable, Sendable {
        public var title: String
        public var minutes: Int
        public var category: TaskCategory?
        public var effort: TaskEffort?
    }

    public static func split(_ task: TaskSnapshot, provider: LLMProvider) async throws -> (subtasks: [Subtask], usage: LLMUsage) {
        let schema = Schema.object(["subtasks": Schema.array(Schema.object([
            "title": Schema.string("子任务标题"),
            "minutes": Schema.integer("预计分钟数，25–90"),
            "category": Schema.nullable(Schema.enumeration(TaskCategory.allCases.map(\.rawValue), description: "分类")),
            "effort": Schema.nullable(Schema.enumeration(["light", "medium", "hard"], description: "难度")),
        ]), description: "2–6 个子任务，按先后顺序")])
        var message = "任务：\(task.displayTitle)"
        if task.plannedMinutes != nil { message += "\n预计总时长：\(task.focusMinutes) 分钟" }
        // Notes only when the user explicitly asks to split this task (data minimization, see design §3.5)
        if !task.notes.isEmpty { message += "\n备注：\n\(task.notes.prefix(2000))" }
        let response = try await provider.send(LLMRequest(system: Prompts.split, messages: [["role": "user", "content": .string(message)]],
                                                          effort: "low", maxTokens: 4000, outputSchema: schema))
        try check(response)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(response.text.utf8))
        let subtasks = (json["subtasks"]?.array ?? []).compactMap { item -> Subtask? in
            guard let title = item["title"]?.string, !title.isEmpty else { return nil }
            return Subtask(title: title, minutes: min(max(item["minutes"]?.int ?? 45, 15), 120),
                           category: item["category"]?.string.flatMap(TaskCategory.init(rawValue:)) ?? task.category,
                           effort: effort(item["effort"]?.string))
        }
        return (Array(subtasks.prefix(6)), response.usage)
    }

    // MARK: Memory

    public static func memory(_ text: String, provider: LLMProvider, now: Date) async throws -> (memory: MemorySnapshot?, usage: LLMUsage) {
        let schema = Schema.object([
            "text": Schema.string("一句简洁的中文描述"),
            "kind": Schema.enumeration(["rule", "preference", "fact"], description: "rule = 每周固定时间"),
            "weekdays": Schema.nullable(Schema.array(Schema.integer("1 = 周日 … 7 = 周六"), description: "适用的星期")),
            "start_time": Schema.nullable(Schema.string("HH:mm")),
            "end_time": Schema.nullable(Schema.string("HH:mm")),
        ])
        let response = try await provider.send(LLMRequest(system: Prompts.memory, messages: [["role": "user", "content": .string(text)]],
                                                          effort: "low", maxTokens: 2000, outputSchema: schema))
        try check(response)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(response.text.utf8))
        return (memorySnapshot(from: json, now: now), response.usage)
    }

    static func memorySnapshot(from json: JSONValue, now: Date) -> MemorySnapshot? {
        guard let text = json["text"]?.string, !text.isEmpty else { return nil }
        let kind = MemoryKind(rawValue: json["kind"]?.string ?? "") ?? .fact
        var constraint: MemoryConstraint?
        if kind == .rule {
            let weekdays = Set((json["weekdays"]?.array ?? []).compactMap(\.int).filter { (1...7).contains($0) })
            if !weekdays.isEmpty, let start = json["start_time"]?.string.flatMap(DateText.minutes),
               let end = json["end_time"]?.string.flatMap(DateText.minutes), end > start {
                constraint = MemoryConstraint(weekdays: weekdays, startMinute: start, endMinute: end)
            }
        }
        return MemorySnapshot(text: text, kind: constraint == nil && kind == .rule ? .fact : kind, constraint: constraint,
                              createdAt: now, updatedAt: now)
    }

    /// 「周三晚上打球」「每天 12:00-13:30 午休」 without the AI
    public static func ruleMemory(_ text: String, now: Date) -> MemorySnapshot {
        let trimmed = text.replacingOccurrences(of: "记住", with: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let names: [(String, Int)] = [("日", 1), ("天", 1), ("一", 2), ("二", 3), ("三", 4), ("四", 5), ("五", 6), ("六", 7)]
        var weekdays: Set<Int> = []
        if trimmed.contains("每天") { weekdays = Set(1...7) }
        if trimmed.contains("工作日") { weekdays.formUnion(2...6) }
        if trimmed.contains("周末") { weekdays.formUnion([1, 7]) }
        for prefix in ["周", "星期", "礼拜"] {
            for (name, day) in names where trimmed.contains(prefix + name) { weekdays.insert(day) }
        }
        var start: Int?, end: Int?
        let clock = try! Regex(#"(\d{1,2})[:：点](\d{2})?"#, as: (Substring, Substring, Substring?).self)
        let times = trimmed.matches(of: clock).compactMap { match -> Int? in
            guard let hour = Int(match.output.1) else { return nil }
            return hour * 60 + (match.output.2.flatMap { Int($0) } ?? 0)
        }
        if times.count >= 2 {
            start = times[0]
            end = times[1]
        } else if trimmed.contains("晚上") {
            start = 19 * 60; end = 21 * 60
        } else if trimmed.contains("中午") {
            start = 12 * 60; end = 13 * 60 + 30
        } else if trimmed.contains("早上") || trimmed.contains("上午") {
            start = 8 * 60; end = 10 * 60
        } else if trimmed.contains("下午") {
            start = 14 * 60; end = 17 * 60
        }
        if let s = start, let e = end, e > s, !weekdays.isEmpty {
            return MemorySnapshot(text: trimmed, kind: .rule, constraint: MemoryConstraint(weekdays: weekdays, startMinute: s, endMinute: e),
                                  createdAt: now, updatedAt: now)
        }
        return MemorySnapshot(text: trimmed, kind: .fact, createdAt: now, updatedAt: now)
    }

    // MARK: Short texts

    public static func text(system: String, facts: String, provider: LLMProvider) async throws -> (text: String, usage: LLMUsage) {
        let response = try await provider.send(LLMRequest(system: system, messages: [["role": "user", "content": .string(facts)]],
                                                          effort: "low", maxTokens: 2000))
        try check(response)
        return (response.text.trimmingCharacters(in: .whitespacesAndNewlines), response.usage)
    }

    // MARK: Helpers

    static func check(_ response: LLMResponse) throws {
        switch response.stopReason {
        case "refusal": throw LLMError.refusal
        case "max_tokens": throw LLMError.truncated
        default: if response.text.isEmpty { throw LLMError.invalidResponse }
        }
    }

    static func priority(_ raw: String?) -> Priority? {
        switch raw { case "urgent": .urgent; case "important": .important; case "normal": .normal; default: nil }
    }

    static func effort(_ raw: String?) -> TaskEffort? {
        switch raw { case "light": .light; case "medium": .medium; case "hard": .hard; default: nil }
    }
}
