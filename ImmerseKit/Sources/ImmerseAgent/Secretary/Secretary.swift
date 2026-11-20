import Foundation
import ImmerseCore
import Observation
import OSLog

/// What the secretary currently knows about the user's schedule, for cards and briefings
public struct SecretaryInsights: Sendable {
    public var today: DayLoad
    public var tomorrow: DayLoad
    public var risks: [DeadlineRiskItem]
    public var calibration: [CalibrationInsight]
    public var behindGoals: [(goal: TaskSnapshot, progress: GoalProgress)]
    public var energy: EnergyCurve
}

/// The app-facing secretary: builds planning contexts, asks the model when the AI is available, falls back to the
/// rule engines when it isn't (or fails), and holds the proposal the user is looking at.
@MainActor
@Observable
public final class Secretary {
    public let ai: AISettings
    /// The proposal shown as ghost blocks on the calendar
    public var activeProposal: PlanProposal?
    /// Memories the model wants to save, waiting for the user's OK
    public var pendingMemories: [MemorySnapshot] = []
    public private(set) var isWorking = false
    /// Last problem worth telling the user about (key invalid, network down…)
    public var notice: String?

    @ObservationIgnored private let taskStore: TaskStore
    @ObservationIgnored private let focusEngine: FocusEngine
    @ObservationIgnored private let memories: MemoryRepository
    @ObservationIgnored public var externalCalendar: ExternalCalendarSource?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let providerFactory: (String) -> LLMProvider
    @ObservationIgnored public var workday = Workday()
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Secretary")

    public init(taskStore: TaskStore, focusEngine: FocusEngine, memories: MemoryRepository, ai: AISettings,
                calendar: Calendar = .app, externalCalendar: ExternalCalendarSource? = nil,
                providerFactory: @escaping (String) -> LLMProvider = { AnthropicHTTPProvider(apiKey: $0) }) {
        self.taskStore = taskStore
        self.focusEngine = focusEngine
        self.memories = memories
        self.ai = ai
        self.calendar = calendar
        self.externalCalendar = externalCalendar
        self.providerFactory = providerFactory
    }

    // MARK: - Context

    public func context(now: Date = .now) -> PlanningContext {
        let since = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: now)) ?? now
        let records = focusEngine.records(in: DateInterval(start: since, end: now.addingTimeInterval(1)))
        let external = externalCalendar.flatMap { source in
            source.isAuthorized ? source.events(in: DateInterval(start: calendar.startOfDay(for: now), duration: 31 * 86400)) : nil
        } ?? []
        let constraints = (try? memories.activeConstraints()) ?? []
        var multipliers: [TaskCategory: Double] = [:]
        for category in TaskCategory.allCases {
            if let value = try? memories.setting(Calibration.settingKey(category), as: Double.self) { multipliers[category] = value }
        }
        return PlanningContext(tasks: taskStore.allTasks(), records: records, externalEvents: external,
                               constraints: constraints, multipliers: multipliers, workday: workday, now: now, calendar: calendar)
    }

    private var provider: LLMProvider? {
        guard ai.isAvailable, let key = ai.apiKey else { return nil }
        return providerFactory(key)
    }

    // MARK: - Planning

    /// Schedule Inbox ideas (all, or the given ones) into the next `days` days
    public func planInbox(ids: [UUID]? = nil, days: Int = 7, instruction: String? = nil, now: Date = .now) async -> PlanProposal? {
        let context = context(now: now)
        let ideas = context.tasks.filter { $0.kind == .idea && $0.status != .done && (ids.map(Set.init)?.contains($0.id) ?? true) }
        guard !ideas.isEmpty else {
            notice = "收集箱是空的"
            return nil
        }
        let start = calendar.startOfDay(for: now)
        let range = DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start) ?? start)
        if let provider {
            let request = """
            现在是 \(DateText.iso(now, calendar: calendar))（\(TimeText.weekday(now, calendar: calendar))），时区 \(calendar.timeZone.identifier)。
            请把收集箱里的这些想法排进 \(DateText.day(range.start, calendar: calendar)) 到 \(DateText.day(range.end.addingTimeInterval(-1), calendar: calendar)) 的空档：
            \(ideas.map { "- \($0.displayTitle)（id: \($0.id.uuidString)）" }.joined(separator: "\n"))
            \(instruction.map { "用户补充：\($0)" } ?? "")
            """
            if let proposal = await runAgent(request: request, context: context, origin: .schedule, provider: provider) { return proposal }
        }
        let slots = SlotFinder.freeSlots(in: range, context: context)
        let result = Scheduler.plan(ideas, into: slots, context: context)
        guard !result.items.isEmpty else {
            notice = "这几天没有足够的空档"
            return nil
        }
        var summary = "把 \(Set(result.items.map(\.operation.taskID)).count) 条想法排进接下来 \(days) 天"
        if !result.unplaced.isEmpty { summary += "，还有 \(result.unplaced.count) 条放不下" }
        return ProposalValidator.validate(PlanProposal(origin: .schedule, summary: summary, items: result.items, createdAt: now),
                                          context: context)
    }

    /// Free-form request from the capture sheet, e.g. 「这周帮我找 2 小时写方案」
    public func ask(_ request: String, now: Date = .now) async -> (proposal: PlanProposal?, reply: String?) {
        guard let provider else { return (nil, nil) }
        let context = context(now: now)
        let message = """
        现在是 \(DateText.iso(now, calendar: calendar))（\(TimeText.weekday(now, calendar: calendar))），时区 \(calendar.timeZone.identifier)。
        用户的请求：\(request)
        """
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await AgentLoop(provider: provider).run(system: Prompts.planner, userMessage: message,
                                                                      toolbox: AgentToolbox(context: context, origin: .schedule))
            ai.record(outcome.usage)
            pendingMemories.append(contentsOf: outcome.pendingMemories)
            return (outcome.proposal, outcome.text.isEmpty ? nil : outcome.text)
        } catch {
            handle(error)
            return (nil, nil)
        }
    }

    /// Push the rest of today back after an interruption (rules only: the order is the user's, the math is simple)
    public func reflow(from start: Date = .now) -> PlanProposal? {
        let context = context(now: start)
        guard let proposal = Reflow.plan(day: start, from: start, context: context) else { return nil }
        return ProposalValidator.validate(proposal, context: context)
    }

    /// Move the least important, not-yet-started events off an overloaded day into the next days' best slots
    public func overloadProposal(day: Date, now: Date = .now) -> PlanProposal? {
        let context = context(now: now)
        let load = LoadEstimator.load(on: day, context: context)
        let deferrals = LoadEstimator.deferrals(for: load, context: context)
        guard !deferrals.isEmpty else { return nil }
        let from = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        let range = DateInterval(start: from, duration: 5 * 86400)
        let slots = SlotFinder.freeSlots(in: range, context: context, excluding: Set(deferrals.map(\.id)))
        let placed = Scheduler.plan(deferrals, into: slots, context: context)
        let items = placed.items.compactMap { item -> PlanProposal.Item? in
            guard case .update(let task) = item.operation else { return nil }
            return PlanProposal.Item(operation: .move(id: task.id, start: task.start, end: task.end),
                                     reason: "\(TimeText.weekday(day, calendar: calendar))排满了，挪到\(TimeText.weekday(task.start, calendar: calendar)) \(TimeText.hhmm(task.start, calendar: calendar))")
        }
        guard !items.isEmpty else { return nil }
        let summary = "\(TimeText.weekday(day, calendar: calendar))排了 \(DurationText.minutes(load.plannedMinutes * 60))，按你的节奏大约能完成 \(DurationText.minutes(load.capacityMinutes * 60))，建议挪走 \(items.count) 项"
        return ProposalValidator.validate(PlanProposal(origin: .overload, summary: summary, items: items, createdAt: now), context: context)
    }

    /// A way to still make a deadline: book the remaining time before it
    public func deadlineRescue(_ risk: DeadlineRiskItem, now: Date = .now) -> PlanProposal? {
        let context = context(now: now)
        guard let deadline = risk.task.deadline, deadline > now else { return nil }
        let slots = SlotFinder.freeSlots(in: DateInterval(start: now, end: deadline), context: context, excluding: [risk.task.id])
        var task = risk.task
        task.plannedMinutes = max(risk.requiredMinutes, 30)
        let placed = Scheduler.plan([task], into: slots, context: context)
        guard !placed.items.isEmpty else { return nil }
        let items = placed.items.map { item -> PlanProposal.Item in
            var item = item
            if case .update(let updated) = item.operation, risk.task.kind == .event {
                item.operation = .move(id: updated.id, start: updated.start, end: updated.end)
            }
            return item
        }
        let summary = "赶在\(TimeText.weekday(deadline, calendar: calendar))截止前完成「\(risk.task.displayTitle)」"
        return ProposalValidator.validate(PlanProposal(origin: .deadline, summary: summary, items: items, createdAt: now), context: context)
    }

    /// Weekly rhythm for a goal, booked into high-energy slots
    public func goalPlan(_ goal: TaskSnapshot, targetMinutes: Int, now: Date = .now) -> (cadence: GoalCadence, proposal: PlanProposal?)? {
        let context = context(now: now)
        let focused = context.focusedMinutes(on: goal.id)
            + context.tasks.filter { $0.goalID == goal.id }.reduce(0) { $0 + context.focusedMinutes(on: $1.id) }
        guard let cadence = GoalBreakdown.cadence(targetMinutes: targetMinutes, focusedMinutes: focused, now: now,
                                                  periodEnd: goal.displayInterval(in: calendar).end, calendar: calendar) else { return nil }
        let proposal = GoalBreakdown.plan(goal: goal, cadence: cadence, context: context)
            .map { ProposalValidator.validate($0, context: context) }
        return (cadence, proposal)
    }

    /// 「本月读完 2 本书」→ minutes, by the model; nil without the AI (the user types it)
    public func estimateGoalMinutes(_ goal: TaskSnapshot) async -> Int? {
        guard let provider else { return nil }
        let schema = Schema.object(["minutes": Schema.integer("完成这个目标大约需要的专注分钟数")])
        do {
            let response = try await provider.send(LLMRequest(
                system: "估计完成用户目标大约需要多少分钟的专注时间，按常识给出一个整数。",
                messages: [["role": "user", "content": .string("目标：\(goal.displayTitle)（\(goal.displayInterval(in: calendar).duration > 8 * 86400 ? "本月" : "本周")）")]],
                effort: "low", maxTokens: 1000, outputSchema: schema))
            ai.record(response.usage)
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(response.text.utf8))
            return json["minutes"]?.int.flatMap { $0 > 0 ? min($0, 100 * 60) : nil }
        } catch {
            handle(error)
            return nil
        }
    }

    // MARK: - Capture

    /// Parsed items for one sentence: the model when available, otherwise the rule parser
    public func capture(_ text: String, now: Date = .now) async -> (drafts: [CaptureDraft], usedAI: Bool) {
        let rule = StructuredCalls.ruleCapture(text, now: now, calendar: calendar)
        guard let provider else { return ([rule], false) }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await StructuredCalls.capture(text, provider: provider, now: now, calendar: calendar)
            ai.record(result.usage)
            return result.drafts.isEmpty ? ([rule], false) : (result.drafts, true)
        } catch {
            handle(error)
            return ([rule], false)
        }
    }

    /// Sub-tasks for a large task, as Inbox ideas linked to it
    public func splitProposal(_ task: TaskSnapshot, now: Date = .now) async -> PlanProposal? {
        guard let provider else {
            notice = "拆分大任务需要开启 AI"
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await StructuredCalls.split(task, provider: provider)
            ai.record(result.usage)
            let items = result.subtasks.enumerated().map { index, subtask in
                PlanProposal.Item(operation: .create(TaskSnapshot(
                    title: subtask.title, start: now.addingTimeInterval(Double(index)), isAllDay: false, priority: task.priority,
                    plannedMinutes: subtask.minutes, kind: .idea, goalID: task.goalID, sortOrder: Double(index),
                    deadline: task.deadline, category: subtask.category, effort: subtask.effort, parentID: task.id, source: .agent)),
                    reason: "第 \(index + 1) 步，约 \(subtask.minutes) 分钟")
            }
            guard !items.isEmpty else { return nil }
            return ProposalValidator.validate(PlanProposal(origin: .split, summary: "把「\(task.displayTitle)」拆成 \(items.count) 步",
                                                           items: items, createdAt: now), context: context(now: now))
        } catch {
            handle(error)
            return nil
        }
    }

    /// 「记住我周三晚上打球」→ a memory for the user to confirm
    public func parseMemory(_ text: String, now: Date = .now) async -> MemorySnapshot {
        if let provider {
            do {
                let result = try await StructuredCalls.memory(text, provider: provider, now: now)
                ai.record(result.usage)
                if let memory = result.memory { return memory }
            } catch {
                handle(error)
            }
        }
        return StructuredCalls.ruleMemory(text, now: now)
    }

    public func saveMemory(_ memory: MemorySnapshot) {
        do {
            try memories.upsert(memory)
        } catch {
            notice = "保存记忆失败：\(error.localizedDescription)"
        }
        pendingMemories.removeAll { $0.id == memory.id }
    }

    // MARK: - Insights & briefings

    public func insights(now: Date = .now) -> SecretaryInsights {
        let context = context(now: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let goals = context.tasks.filter { $0.isActiveGoal(now: now, calendar: calendar) && $0.status != .done }
        let behind = goals.compactMap { goal -> (TaskSnapshot, GoalProgress)? in
            let progress = GoalProgress(goal: goal, linkedEvents: context.tasks.filter { $0.goalID == goal.id && $0.kind == .event },
                                        records: context.records, now: now, calendar: calendar)
            return progress.isBehind ? (goal, progress) : nil
        }
        return SecretaryInsights(
            today: LoadEstimator.load(on: now, context: context),
            tomorrow: LoadEstimator.load(on: tomorrow, context: context),
            risks: DeadlineRisk.assess(context: context),
            calibration: Calibration.insights(tasks: context.tasks, records: context.records, accepted: context.multipliers),
            behindGoals: behind,
            energy: context.energy)
    }

    public func focusBriefing(for task: TaskSnapshot, now: Date = .now) -> FocusBriefing {
        Briefing.beforeFocus(on: task, context: context(now: now))
    }

    public func acceptCalibration(_ insight: CalibrationInsight) {
        try? memories.setSetting(insight.suggestedMultiplier, for: Calibration.settingKey(insight.category))
    }

    /// Two or three sentences about the day for the evening review; a template without the AI
    public func reviewSummary(done: Int, total: Int, focusedMinutes: Int, interruptions: Int) async -> String {
        let fallback = total == 0 ? "今天没有安排任务。" :
            "今天完成了 \(done)/\(total) 项，专注 \(DurationText.minutes(focusedMinutes * 60))。" +
            (done < total ? "没做完的可以顺延到明天。" : "全部完成，早点休息。")
        guard let provider else { return fallback }
        let facts = "今天计划 \(total) 项，完成 \(done) 项；专注 \(focusedMinutes) 分钟；被打断或放弃 \(interruptions) 次。"
        do {
            let result = try await StructuredCalls.text(system: Prompts.review, facts: facts, provider: provider)
            ai.record(result.usage)
            return result.text.isEmpty ? fallback : result.text
        } catch {
            handle(error)
            return fallback
        }
    }

    // MARK: - Proposal lifecycle

    public func present(_ proposal: PlanProposal?) {
        activeProposal = proposal.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func toggle(_ itemID: UUID) {
        guard let index = activeProposal?.items.firstIndex(where: { $0.id == itemID }) else { return }
        activeProposal?.items[index].isSelected.toggle()
        if let proposal = activeProposal { activeProposal = ProposalValidator.validate(proposal, context: context()) }
    }

    /// Writes the selected items; returns how many tasks changed
    @discardableResult
    public func applyActiveProposal() -> Int {
        guard let proposal = activeProposal else { return 0 }
        let count = ProposalApplier.apply(proposal, to: taskStore)
        activeProposal = nil
        taskStore.toast = Toast(message: "已应用 \(count) 项安排", showsUndo: true)
        return count
    }

    public func discardActiveProposal() {
        activeProposal = nil
    }

    // MARK: - Errors

    private func runAgent(request: String, context: PlanningContext, origin: PlanProposal.Origin,
                          provider: LLMProvider) async -> PlanProposal? {
        isWorking = true
        defer { isWorking = false }
        do {
            let toolbox = AgentToolbox(context: context, origin: origin)
            let outcome = try await AgentLoop(provider: provider).run(
                system: Prompts.planner, userMessage: request, toolbox: toolbox)
            ai.record(outcome.usage)
            pendingMemories.append(contentsOf: outcome.pendingMemories)
            if outcome.proposal == nil, !outcome.text.isEmpty { notice = outcome.text }
            return outcome.proposal
        } catch {
            handle(error)
            return nil
        }
    }

    private func handle(_ error: Error) {
        logger.error("AI request failed: \(error.localizedDescription, privacy: .public)")
        if let error = error as? LLMError {
            if error == .invalidKey { ai.markKeyInvalid() }
            notice = (error.errorDescription ?? "AI 暂时不可用") + "，已改用规则安排"
        } else {
            notice = "AI 暂时不可用，已改用规则安排"
        }
    }
}
