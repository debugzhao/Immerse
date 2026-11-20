import Foundation
import ImmerseCore

/// The tools the model can call. Read tools answer from `PlanningContext` and the engines; `create_task` /
/// `update_task` only add operations to a draft, `propose_plan` validates the draft into a `PlanProposal` and ends
/// the run. Nothing here writes to the store — applying a proposal is the user's call (see `ProposalApplier`).
@MainActor
public final class AgentToolbox {
    public private(set) var context: PlanningContext
    public private(set) var draft: [PlanProposal.Item] = []
    /// Set by `propose_plan`
    public private(set) var proposal: PlanProposal?
    /// Memories the model asked to save; shown to the user for confirmation
    public private(set) var pendingMemories: [MemorySnapshot] = []
    private let origin: PlanProposal.Origin

    public init(context: PlanningContext, origin: PlanProposal.Origin = .schedule) {
        self.context = context
        self.origin = origin
    }

    public var isFinished: Bool { proposal != nil }

    // MARK: - Definitions

    public nonisolated static let definitions: [JSONValue] = {
        let iso = "ISO 8601 date-time with time zone offset, e.g. 2026-11-20T09:00:00+08:00"
        let priority = Schema.nullable(Schema.enumeration(["urgent", "important", "normal"], description: "优先级"))
        let category = Schema.nullable(Schema.enumeration(TaskCategory.allCases.map(\.rawValue), description: "任务分类"))
        let effort = Schema.nullable(Schema.enumeration(["light", "medium", "hard"], description: "难度：hard = 需要整块精力"))
        let tools: [(String, String, JSONValue)] = [
            ("list_tasks", "List the user's tasks overlapping a time range. Ideas (Inbox) and goals are returned regardless of range when their kind is requested.",
             Schema.object([
                "range_start": Schema.string(iso), "range_end": Schema.string(iso),
                "kinds": Schema.array(Schema.enumeration(["event", "idea", "goal"], description: "kind"), description: "Which kinds to include"),
                "include_done": Schema.boolean("Include finished tasks"),
             ])),
            ("find_free_slots", "Free time inside the user's workday (9:00–22:00) in a range, around events, system-calendar meetings and remembered rules. Each slot has energy_score 0–1 (how well the user usually focuses then).",
             Schema.object([
                "range_start": Schema.string(iso), "range_end": Schema.string(iso),
                "min_minutes": Schema.nullable(Schema.integer("Shortest slot to return, default 30")),
             ])),
            ("get_insights", "Computed numbers about the user's schedule. Always use these numbers instead of estimating yourself.",
             Schema.object([
                "date": Schema.nullable(Schema.string("Day for load, YYYY-MM-DD; default today", format: "date")),
                "kinds": Schema.array(Schema.enumeration(["load", "deadline_risk", "calibration", "energy", "goals_behind"], description: "insight"),
                                      description: "Which insights to compute"),
             ])),
            ("read_memory", "Things the user asked the secretary to remember, e.g. recurring busy times. Never schedule into a rule's time.",
             Schema.object([:])),
            ("create_task", "Add a new event (or an Inbox idea) to the draft plan. Nothing is saved until the user approves the plan.",
             Schema.object([
                "title": Schema.string("Short task title in the user's language"),
                "kind": Schema.enumeration(["event", "idea"], description: "event = on the calendar at `start`; idea = Inbox, no time"),
                "start": Schema.nullable(Schema.string(iso)),
                "minutes": Schema.nullable(Schema.integer("Duration in minutes")),
                "priority": priority, "category": category, "effort": effort,
                "deadline": Schema.nullable(Schema.string(iso)),
                "goal_id": Schema.nullable(Schema.string("Goal this session works towards", format: "uuid")),
                "parent_id": Schema.nullable(Schema.string("Parent task when this is a sub-task", format: "uuid")),
                "reason": Schema.string("One short sentence in Chinese telling the user why, e.g. 「排在 9:00，这是你精力最好的时段」"),
             ])),
            ("update_task", "Change an existing task in the draft plan: schedule an Inbox idea, move an event, or send it back to the Inbox.",
             Schema.object([
                "id": Schema.string("Task id from list_tasks", format: "uuid"),
                "title": Schema.nullable(Schema.string("New title")),
                "start": Schema.nullable(Schema.string(iso)),
                "minutes": Schema.nullable(Schema.integer("New duration in minutes")),
                "priority": priority, "category": category, "effort": effort,
                "deadline": Schema.nullable(Schema.string(iso)),
                "to_inbox": Schema.boolean("true = take it off the calendar and back to the Inbox"),
                "reason": Schema.string("One short sentence in Chinese telling the user why"),
             ])),
            ("propose_plan", "Finish: validate the draft and show it to the user as a proposal they can apply or reject. Call exactly once, after all create_task / update_task calls.",
             Schema.object(["summary": Schema.string("One line in Chinese summarizing the plan, e.g. 「把 5 条想法排进本周的 4 个空档」")])),
            ("write_memory", "Ask to remember something about the user. The user confirms before it is saved.",
             Schema.object([
                "text": Schema.string("What to remember, in the user's words"),
                "kind": Schema.enumeration(["rule", "preference", "fact"], description: "rule = recurring busy time the scheduler must avoid"),
                "weekdays": Schema.nullable(Schema.array(Schema.integer("1 = Sunday … 7 = Saturday"), description: "Days a rule applies")),
                "start_time": Schema.nullable(Schema.string("HH:mm")),
                "end_time": Schema.nullable(Schema.string("HH:mm")),
             ])),
        ]
        return tools.map { name, description, schema in
            ["name": .string(name), "description": .string(description), "input_schema": schema, "strict": true]
        }
    }()

    // MARK: - Dispatch

    /// Runs one tool call; errors come back as `is_error` results so the model can correct itself
    public func execute(name: String, input: JSONValue) -> (result: JSONValue, isError: Bool) {
        do {
            let result: JSONValue = switch name {
            case "list_tasks": try listTasks(input)
            case "find_free_slots": try findFreeSlots(input)
            case "get_insights": try getInsights(input)
            case "read_memory": readMemory()
            case "create_task": try createTask(input)
            case "update_task": try updateTask(input)
            case "propose_plan": try proposePlan(input)
            case "write_memory": try writeMemory(input)
            default: throw ToolError("Unknown tool \(name)")
            }
            return (result, false)
        } catch let error as ToolError {
            return (.string(error.message), true)
        } catch {
            return (.string(error.localizedDescription), true)
        }
    }

    struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: - Read tools

    private func listTasks(_ input: JSONValue) throws -> JSONValue {
        let range = try dateRange(input)
        let kinds = Set((input["kinds"]?.array ?? []).compactMap { $0.string.flatMap(TaskKind.init(rawValue:)) })
        let includeDone = input["include_done"]?.bool ?? false
        let calendar = context.calendar
        let tasks = context.tasks.filter { task in
            guard kinds.isEmpty || kinds.contains(task.kind) else { return false }
            guard includeDone || task.status != .done else { return false }
            return task.kind != .event || task.displayInterval(in: calendar).overlapsHalfOpen(range)
        }
        .sorted { $0.start < $1.start }
        let external = context.externalEvents.filter { DateInterval(start: $0.start, end: $0.end).overlapsHalfOpen(range) }
        return [
            "tasks": .array(tasks.map(dto)),
            "calendar_events": .array(external.map { event in
                ["title": .string(event.title), "start": .string(DateText.iso(event.start, calendar: calendar)),
                 "end": .string(DateText.iso(event.end, calendar: calendar)), "all_day": .bool(event.isAllDay),
                 "note": "system calendar, read-only"]
            }),
        ]
    }

    private func findFreeSlots(_ input: JSONValue) throws -> JSONValue {
        let range = try dateRange(input)
        let minimum = input["min_minutes"]?.int ?? SlotFinder.minimumMinutes
        // Time already claimed by the draft counts as busy
        var working = context
        working.tasks = applyingDraft(to: context.tasks)
        let slots = SlotFinder.freeSlots(in: range, context: working, minimumMinutes: max(minimum, 15))
        return ["slots": .array(slots.prefix(40).map { slot in
            ["start": .string(DateText.iso(slot.interval.start, calendar: context.calendar)),
             "end": .string(DateText.iso(slot.interval.end, calendar: context.calendar)),
             "minutes": .number(Double(slot.minutes)),
             "energy_score": .number((slot.energy * 100).rounded() / 100)]
        })]
    }

    private func getInsights(_ input: JSONValue) throws -> JSONValue {
        let calendar = context.calendar
        let day = try input["date"]?.string.map { try DateText.parseDay($0, calendar: calendar) } ?? context.now
        var result: [String: JSONValue] = [:]
        for kind in (input["kinds"]?.array ?? []).compactMap(\.string) {
            switch kind {
            case "load":
                let load = LoadEstimator.load(on: day, context: context)
                result["load"] = ["date": .string(DateText.day(load.day, calendar: calendar)),
                                  "planned_minutes": .number(Double(load.plannedMinutes)),
                                  "capacity_minutes": .number(Double(load.capacityMinutes)),
                                  "overload_minutes": .number(Double(load.overloadMinutes)),
                                  "capacity_is_personal": .bool(load.capacityIsPersonal)]
            case "deadline_risk":
                result["deadline_risk"] = .array(DeadlineRisk.assess(context: context).map { risk in
                    ["task_id": .string(risk.task.id.uuidString), "title": .string(risk.task.displayTitle),
                     "kind": .string(risk.kind.rawValue), "required_minutes": .number(Double(risk.requiredMinutes)),
                     "available_minutes": .number(Double(risk.availableMinutes)), "delay_days": .number(Double(risk.delayDays))]
                })
            case "calibration":
                result["calibration"] = .array(Calibration.ratios(tasks: context.tasks, records: context.records).map { category, value in
                    ["category": .string(category.rawValue), "actual_over_planned": .number((value.ratio * 100).rounded() / 100),
                     "samples": .number(Double(value.samples)),
                     "accepted_multiplier": context.multipliers[category].map { .number($0) } ?? .null]
                })
            case "energy":
                let curve = context.energy
                result["energy"] = ["peak_hours": .array(curve.peakHours().map { .number(Double($0)) }),
                                    "is_personalized": .bool(curve.isPersonalized),
                                    "sessions": .number(Double(curve.sampleCount))]
            case "goals_behind":
                result["goals_behind"] = .array(context.tasks.filter { $0.isActiveGoal(now: context.now, calendar: calendar) && $0.status != .done }
                    .compactMap { goal -> JSONValue? in
                        let linked = context.tasks.filter { $0.goalID == goal.id && $0.kind == .event }
                        let progress = GoalProgress(goal: goal, linkedEvents: linked, records: context.records,
                                                    now: context.now, calendar: calendar)
                        guard progress.isBehind else { return nil }
                        return ["goal_id": .string(goal.id.uuidString), "title": .string(goal.displayTitle),
                                "percent": .number(Double(progress.percent)), "days_left": .number(Double(progress.daysLeft)),
                                "target_minutes": progress.targetMinutes.map { .number(Double($0)) } ?? .null,
                                "focused_minutes": .number(Double(progress.focusedMinutes))]
                    })
            default:
                throw ToolError("Unknown insight \(kind)")
            }
        }
        return .object(result)
    }

    private func readMemory() -> JSONValue {
        ["rules": .array(context.constraints.map { constraint in
            ["weekdays": .array(constraint.weekdays.sorted().map { .number(Double($0)) }),
             "start": .string(DateText.clock(constraint.startMinute)), "end": .string(DateText.clock(constraint.endMinute))]
        })]
    }

    // MARK: - Draft tools

    private func createTask(_ input: JSONValue) throws -> JSONValue {
        guard let title = input["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw ToolError("title is required")
        }
        let reason = try reasonText(input)
        let kind: TaskKind = input["kind"]?.string == "idea" ? .idea : .event
        let calendar = context.calendar
        let start = try input["start"]?.string.map { try DateText.parse($0) }
        let minutes = input["minutes"]?.int
        if kind == .event && start == nil { throw ToolError("start is required for an event") }
        if let minutes, minutes <= 0 || minutes > 12 * 60 { throw ToolError("minutes must be between 1 and 720") }
        let begin = start ?? context.now
        let task = TaskSnapshot(
            title: title, start: begin,
            end: kind == .event ? begin.addingTimeInterval(TimeInterval((minutes ?? 60) * 60)) : nil,
            isAllDay: false, priority: try priority(input) ?? .normal, plannedMinutes: minutes, kind: kind,
            goalID: try uuid(input["goal_id"]), deadline: try input["deadline"]?.string.map { try DateText.parse($0) },
            category: try category(input), effort: try effort(input), parentID: try uuid(input["parent_id"]), source: .agent)
        if let goalID = task.goalID, !context.tasks.contains(where: { $0.id == goalID && $0.kind == .goal }) {
            throw ToolError("goal_id \(goalID) is not a goal")
        }
        if kind == .event, let conflict = conflict(for: task) {
            throw ToolError("\(DateText.iso(begin, calendar: calendar)) overlaps \(conflict); call find_free_slots and pick a free time")
        }
        let item = PlanProposal.Item(operation: .create(task), reason: reason)
        draft.append(item)
        return ["ok": true, "task_id": .string(task.id.uuidString)]
    }

    private func updateTask(_ input: JSONValue) throws -> JSONValue {
        guard let id = try uuid(input["id"]), let existing = current(id) else { throw ToolError("Unknown task id") }
        let reason = try reasonText(input)
        if input["to_inbox"]?.bool == true {
            draft.removeAll { $0.operation.taskID == id }
            draft.append(PlanProposal.Item(operation: .toInbox(id: id), reason: reason))
            return ["ok": true]
        }
        var task = existing
        if let title = input["title"]?.string, !title.isEmpty { task.title = title }
        if let priority = try priority(input) { task.priority = priority }
        if let category = try category(input) { task.category = category }
        if let effort = try effort(input) { task.effort = effort }
        if let deadline = input["deadline"]?.string { task.deadline = try DateText.parse(deadline) }
        let minutes = input["minutes"]?.int
        if let minutes { task.plannedMinutes = minutes }
        if let startText = input["start"]?.string {
            let start = try DateText.parse(startText)
            let duration = TimeInterval((minutes ?? context.estimatedMinutes(for: existing)) * 60)
            task.kind = .event
            task.isAllDay = false
            task.start = start
            task.end = start.addingTimeInterval(duration)
            if let conflict = conflict(for: task) {
                throw ToolError("\(startText) overlaps \(conflict); call find_free_slots and pick a free time")
            }
        }
        draft.removeAll { $0.operation.taskID == id }
        draft.append(PlanProposal.Item(operation: .update(task), reason: reason))
        return ["ok": true]
    }

    private func proposePlan(_ input: JSONValue) throws -> JSONValue {
        guard !draft.isEmpty else { throw ToolError("The draft is empty; add changes with create_task / update_task first") }
        let summary = input["summary"]?.string ?? "秘书的安排建议"
        let validated = ProposalValidator.validate(
            PlanProposal(origin: origin, summary: summary, items: draft, createdAt: context.now), context: context)
        proposal = validated
        return ["ok": true, "items": .number(Double(validated.items.count)),
                "warnings": .array(validated.warnings.map { .string($0) })]
    }

    private func writeMemory(_ input: JSONValue) throws -> JSONValue {
        guard let text = input["text"]?.string, !text.isEmpty else { throw ToolError("text is required") }
        let kind = MemoryKind(rawValue: input["kind"]?.string ?? "") ?? .fact
        var constraint: MemoryConstraint?
        if kind == .rule {
            let weekdays = Set((input["weekdays"]?.array ?? []).compactMap(\.int).filter { (1...7).contains($0) })
            guard !weekdays.isEmpty, let start = input["start_time"]?.string.flatMap(DateText.minutes),
                  let end = input["end_time"]?.string.flatMap(DateText.minutes), end > start else {
                throw ToolError("A rule needs weekdays, start_time and end_time (HH:mm, end after start)")
            }
            constraint = MemoryConstraint(weekdays: weekdays, startMinute: start, endMinute: end)
        }
        pendingMemories.append(MemorySnapshot(text: text, kind: kind, constraint: constraint, origin: .explicit,
                                              createdAt: context.now, updatedAt: context.now))
        return ["ok": true, "note": "The user will confirm before it is saved"]
    }

    // MARK: - Helpers

    func current(_ id: UUID) -> TaskSnapshot? {
        if let drafted = draft.last(where: { $0.operation.taskID == id }) {
            switch drafted.operation {
            case .create(let task), .update(let task): return task
            default: break
            }
        }
        return context.tasks.first { $0.id == id }
    }

    /// The tasks as they would be with the draft applied (for free-slot and conflict checks)
    func applyingDraft(to tasks: [TaskSnapshot]) -> [TaskSnapshot] {
        var byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in draft {
            switch item.operation {
            case .create(let task), .update(let task): byID[task.id] = task
            case .move(let id, let start, let end):
                byID[id]?.start = start
                byID[id]?.end = end
            case .toInbox(let id): byID[id]?.kind = .idea
            }
        }
        return Array(byID.values)
    }

    private func conflict(for task: TaskSnapshot) -> String? {
        var working = context
        working.tasks = applyingDraft(to: context.tasks)
        let interval = task.displayInterval(in: context.calendar)
        let others = working.tasks.filter { $0.id != task.id && $0.kind == .event && !$0.isAllDay && $0.status != .done }
        if let clash = others.first(where: { $0.displayInterval(in: context.calendar).overlapsHalfOpen(interval) }) {
            return "「\(clash.displayTitle)」"
        }
        if let meeting = context.externalEvents.first(where: { !$0.isAllDay && DateInterval(start: $0.start, end: $0.end).overlapsHalfOpen(interval) }) {
            return "「\(meeting.title)」(system calendar)"
        }
        if context.constraints.contains(where: { !$0.busyIntervals(in: interval, calendar: context.calendar).isEmpty }) {
            return "a remembered rule"
        }
        return nil
    }

    private func dto(_ task: TaskSnapshot) -> JSONValue {
        let calendar = context.calendar
        var object: [String: JSONValue] = [
            "id": .string(task.id.uuidString), "title": .string(task.displayTitle), "kind": .string(task.kind.rawValue),
            "status": .string(task.status.rawValue), "priority": .string(priorityName(task.priority)),
            "estimated_minutes": .number(Double(context.estimatedMinutes(for: task))),
        ]
        if task.kind == .event {
            let interval = task.displayInterval(in: calendar)
            object["start"] = .string(DateText.iso(interval.start, calendar: calendar))
            object["end"] = .string(DateText.iso(interval.end, calendar: calendar))
            object["all_day"] = .bool(task.isAllDay)
            if let place = task.place, !place.isEmpty { object["fixed"] = "has a place; don't move" }
        }
        if let deadline = task.deadline { object["deadline"] = .string(DateText.iso(deadline, calendar: calendar)) }
        if let category = task.category { object["category"] = .string(category.rawValue) }
        if let effort = task.effort { object["effort"] = .string(effortName(effort)) }
        if let goalID = task.goalID { object["goal_id"] = .string(goalID.uuidString) }
        if let parentID = task.parentID { object["parent_id"] = .string(parentID.uuidString) }
        if task.kind == .goal { object["target_minutes"] = task.targetMinutes.map { .number(Double($0)) } ?? .null }
        return .object(object)
    }

    private func dateRange(_ input: JSONValue) throws -> DateInterval {
        guard let startText = input["range_start"]?.string, let endText = input["range_end"]?.string else {
            throw ToolError("range_start and range_end are required")
        }
        let start = try DateText.parse(startText), end = try DateText.parse(endText)
        guard end > start else { throw ToolError("range_end must be after range_start") }
        guard end.timeIntervalSince(start) <= 62 * 86400 else { throw ToolError("Range is limited to 62 days") }
        return DateInterval(start: start, end: end)
    }

    private func reasonText(_ input: JSONValue) throws -> String {
        guard let reason = input["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ToolError("reason is required: one short sentence telling the user why")
        }
        return reason
    }

    private func uuid(_ value: JSONValue?) throws -> UUID? {
        guard let text = value?.string else { return nil }
        guard let id = UUID(uuidString: text) else { throw ToolError("\(text) is not a valid id") }
        return id
    }

    private func priority(_ input: JSONValue) throws -> Priority? {
        switch input["priority"]?.string {
        case nil: nil
        case "urgent": .urgent
        case "important": .important
        case "normal": .normal
        case let other?: throw ToolError("Unknown priority \(other)")
        }
    }

    private func category(_ input: JSONValue) throws -> TaskCategory? {
        guard let raw = input["category"]?.string else { return nil }
        guard let category = TaskCategory(rawValue: raw) else { throw ToolError("Unknown category \(raw)") }
        return category
    }

    private func effort(_ input: JSONValue) throws -> TaskEffort? {
        switch input["effort"]?.string {
        case nil: nil
        case "light": .light
        case "medium": .medium
        case "hard": .hard
        case let other?: throw ToolError("Unknown effort \(other)")
        }
    }

    private func priorityName(_ priority: Priority) -> String {
        switch priority { case .urgent: "urgent"; case .important: "important"; case .normal: "normal" }
    }

    private func effortName(_ effort: TaskEffort) -> String {
        switch effort { case .light: "light"; case .medium: "medium"; case .hard: "hard" }
    }
}

/// Date formatting for the model: ISO 8601 with the user's offset, so times read naturally ("09:00+08:00")
public enum DateText {
    public static func iso(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Accepts "2026-11-20T09:00:00+08:00", with fractional seconds, or without seconds
    public static func parse(_ text: String) throws -> Date {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        // "2026-11-20T09:00+08:00": add the missing seconds
        if let range = text.range(of: #"T\d{2}:\d{2}(?=[+-Z])"#, options: .regularExpression) {
            var fixed = text
            fixed.insert(contentsOf: ":00", at: range.upperBound)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: fixed) { return date }
        }
        throw AgentToolbox.ToolError("\(text) is not an ISO 8601 date-time with offset")
    }

    public static func parseDay(_ text: String, calendar: Calendar) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            throw AgentToolbox.ToolError("\(text) is not YYYY-MM-DD")
        }
        return date
    }

    public static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// "19:30" → 1170
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return min(parts[0] * 60 + parts[1], 24 * 60)
    }
}
