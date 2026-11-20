import Foundation
import ImmerseCore
import Testing
@testable import ImmerseAgent

@MainActor
struct ProposalTests {
    @Test func 校验丢掉无效项并给出冲突和过载警告() {
        let existing = Fixture.event("已有", 18, 10)
        let meeting = ExternalEvent(id: "m", title: "周会", start: Fixture.date(18, 14), end: Fixture.date(18, 15), isAllDay: false)
        let context = Fixture.context(tasks: [existing], external: [meeting])
        let proposal = PlanProposal(origin: .schedule, summary: "test", items: [
            .init(operation: .create(Fixture.event("撞会议", 18, 14)), reason: "r"),
            .init(operation: .create(Fixture.event("撞日程", 18, 10, 30)), reason: "r"),
            .init(operation: .create(Fixture.event("没理由", 18, 16)), reason: " "),
            .init(operation: .move(id: UUID(), start: Fixture.date(18, 9), end: nil), reason: "r"),
            .init(operation: .create(Fixture.event("超长", 18, 16, minutes: 420)), reason: "r"),
        ], createdAt: Fixture.now)
        let validated = ProposalValidator.validate(proposal, context: context)
        #expect(validated.items.count == 3)
        #expect(validated.warnings.contains("「撞会议」和「周会」时间冲突"))
        #expect(validated.warnings.contains { $0.contains("撞日程") && $0.contains("已有") })
        #expect(validated.warnings.contains { $0.contains("过载") })
    }

    @Test func 应用提案是一步撤销() {
        let idea = Fixture.idea("看书", minutes: 45)
        let moved = Fixture.event("开会", 18, 10)
        let repository = InMemoryTaskRepository(items: [idea, moved])
        let store = TaskStore(repository: repository)
        var scheduled = idea
        scheduled.kind = .event
        scheduled.start = Fixture.date(18, 15)
        scheduled.end = Fixture.date(18, 15, 45)
        let proposal = PlanProposal(origin: .schedule, summary: "s", items: [
            .init(operation: .update(scheduled), reason: "r"),
            .init(operation: .move(id: moved.id, start: Fixture.date(18, 11), end: Fixture.date(18, 12)), reason: "r"),
            .init(operation: .create(Fixture.event("新的", 18, 16)), reason: "r"),
            .init(operation: .create(Fixture.event("没选", 18, 17)), reason: "r", isSelected: false),
        ], createdAt: Fixture.now)

        #expect(ProposalApplier.apply(proposal, to: store) == 3)
        #expect(store.task(id: idea.id)?.kind == .event)
        #expect(store.task(id: idea.id)?.proposalID == proposal.id)
        #expect(store.task(id: moved.id)?.start == Fixture.date(18, 11))
        #expect(repository.items.count == 3)

        store.undo()
        #expect(store.task(id: idea.id)?.kind == .idea)
        #expect(store.task(id: moved.id)?.start == Fixture.date(18, 10))
        #expect(repository.items.count == 2)
    }

    @Test func 提案可以存盘和过期() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProposalStore(directory: directory)
        let fresh = PlanProposal(origin: .review, summary: "a", items: [.init(operation: .toInbox(id: UUID()), reason: "r")])
        let stale = PlanProposal(origin: .review, summary: "b", items: [], createdAt: .now.addingTimeInterval(-90_000))
        store.save(fresh)
        store.save(stale)
        #expect(store.all().map(\.id) == [fresh.id])
        #expect(store.proposal(id: fresh.id) == fresh)
        store.remove(id: fresh.id)
        #expect(store.all().isEmpty)
    }
}

@MainActor
struct ToolboxTests {
    @Test func 工具定义都是严格模式() {
        for tool in AgentToolbox.definitions {
            #expect(tool["strict"] == true)
            #expect(tool["input_schema"]?["additionalProperties"] == false)
            let properties = tool["input_schema"]?["properties"]?.jsonString ?? ""
            let required = tool["input_schema"]?["required"]?.array?.count ?? -1
            #expect(required == (try? JSONDecoder().decode([String: JSONValue].self, from: Data(properties.utf8)))?.count)
        }
        #expect(AgentToolbox.definitions.compactMap { $0["name"]?.string }.contains("propose_plan"))
        // The write tools the user controls are never offered to the model
        #expect(!AgentToolbox.definitions.contains { ["apply_plan", "start_focus"].contains($0["name"]?.string ?? "") })
    }

    @Test func 草稿冲突时报错让模型重选() {
        let busy = Fixture.event("已有", 18, 10)
        let toolbox = AgentToolbox(context: Fixture.context(tasks: [busy]))
        let (result, isError) = toolbox.execute(name: "create_task", input: [
            "title": "写方案", "kind": "event", "start": "2026-11-18T10:30:00+08:00", "minutes": 60,
            "priority": nil, "category": nil, "effort": nil, "deadline": nil, "goal_id": nil, "parent_id": nil, "reason": "r",
        ])
        #expect(isError)
        #expect(result.string?.contains("find_free_slots") == true)
        #expect(toolbox.draft.isEmpty)
    }

    @Test func 草稿占用的时间不再算空档() {
        let toolbox = AgentToolbox(context: Fixture.context())
        _ = toolbox.execute(name: "create_task", input: [
            "title": "写方案", "kind": "event", "start": "2026-11-18T09:00:00+08:00", "minutes": 120,
            "priority": "important", "category": "writing", "effort": "hard", "deadline": nil, "goal_id": nil, "parent_id": nil,
            "reason": "上午精力最好",
        ])
        let (slots, _) = toolbox.execute(name: "find_free_slots", input: [
            "range_start": "2026-11-18T00:00:00+08:00", "range_end": "2026-11-19T00:00:00+08:00", "min_minutes": nil,
        ])
        #expect(slots["slots"]?.array?.first?["start"]?.string == "2026-11-18T11:00:00+08:00")
    }

    @Test func 提议计划需要非空草稿() {
        let idea = Fixture.idea("看书", minutes: 45)
        let toolbox = AgentToolbox(context: Fixture.context(tasks: [idea]))
        #expect(toolbox.execute(name: "propose_plan", input: ["summary": "x"]).isError)
        _ = toolbox.execute(name: "update_task", input: [
            "id": .string(idea.id.uuidString), "title": nil, "start": "2026-11-18T15:00:00+08:00", "minutes": nil,
            "priority": nil, "category": nil, "effort": nil, "deadline": nil, "to_inbox": false, "reason": "下午有空",
        ])
        let (result, isError) = toolbox.execute(name: "propose_plan", input: ["summary": "把看书排到下午"])
        #expect(!isError)
        #expect(result["items"] == 1)
        guard case .update(let task)? = toolbox.proposal?.items.first?.operation else { Issue.record("no update"); return }
        #expect(task.kind == .event)
        #expect(task.end == Fixture.date(18, 15, 45))
    }

    @Test func 记忆规则需要完整时间() {
        let toolbox = AgentToolbox(context: Fixture.context())
        #expect(toolbox.execute(name: "write_memory", input: [
            "text": "周三打球", "kind": "rule", "weekdays": [4], "start_time": nil, "end_time": nil,
        ]).isError)
        #expect(!toolbox.execute(name: "write_memory", input: [
            "text": "周三晚上打球", "kind": "rule", "weekdays": [4], "start_time": "19:00", "end_time": "21:00",
        ]).isError)
        #expect(toolbox.pendingMemories.first?.constraint == MemoryConstraint(weekdays: [4], startMinute: 1140, endMinute: 1260))
    }

    @Test func 洞察里的数字来自引擎() {
        let toolbox = AgentToolbox(context: Fixture.context(tasks: [Fixture.event("长会", 18, 9, minutes: 480)]))
        let (result, _) = toolbox.execute(name: "get_insights", input: ["date": "2026-11-18", "kinds": ["load", "energy"]])
        #expect(result["load"]?["planned_minutes"] == 480)
        #expect(result["load"]?["overload_minutes"] == 120)
        #expect(result["energy"]?["is_personalized"] == false)
    }
}

@MainActor
struct AgentLoopTests {
    @Test func 多轮工具调用直到提出计划() async throws {
        let idea = Fixture.idea("看书", minutes: 45)
        let provider = ScriptedProvider([
            .success(ScriptedProvider.toolUse([
                ("list_tasks", ["range_start": "2026-11-18T00:00:00+08:00", "range_end": "2026-11-25T00:00:00+08:00",
                                "kinds": ["idea"], "include_done": false]),
                ("find_free_slots", ["range_start": "2026-11-18T00:00:00+08:00", "range_end": "2026-11-19T00:00:00+08:00", "min_minutes": nil]),
            ])),
            .success(ScriptedProvider.toolUse([
                ("update_task", ["id": .string(idea.id.uuidString), "title": nil, "start": "2026-11-18T09:00:00+08:00", "minutes": nil,
                                 "priority": nil, "category": nil, "effort": nil, "deadline": nil, "to_inbox": false, "reason": "上午最清醒"]),
                ("propose_plan", ["summary": "把看书排到今天上午"]),
            ])),
        ])
        let toolbox = AgentToolbox(context: Fixture.context(tasks: [idea]))
        let outcome = try await AgentLoop(provider: provider).run(system: Prompts.planner, userMessage: "排一下", toolbox: toolbox)

        #expect(outcome.turns == 2)
        #expect(outcome.proposal?.summary == "把看书排到今天上午")
        #expect(outcome.usage.inputTokens == 200)
        // Second request carries the first assistant turn unchanged (thinking block included) and both tool results
        let second = provider.requests[1].messages
        #expect(second.count == 3)
        #expect(second[1]["content"]?.array?.first?["type"] == "thinking")
        #expect(second[1]["content"]?.array?.first?["signature"] == "sig-abc")
        let results = second[2]["content"]?.array ?? []
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0["type"] == "tool_result" })
        #expect(results.map { $0["tool_use_id"]?.string ?? "" } == ["toolu_0_list_tasks", "toolu_1_find_free_slots"])
    }

    @Test func 工具出错会告诉模型() async throws {
        let provider = ScriptedProvider([
            .success(ScriptedProvider.toolUse([("propose_plan", ["summary": "空的"])])),
            .success(ScriptedProvider.text("没有需要调整的安排。")),
        ])
        let outcome = try await AgentLoop(provider: provider).run(system: "s", userMessage: "u", toolbox: AgentToolbox(context: Fixture.context()))
        #expect(outcome.proposal == nil)
        #expect(outcome.text == "没有需要调整的安排。")
        #expect(provider.requests[1].messages.last?["content"]?.array?.first?["is_error"] == true)
    }

    @Test func 拒绝和截断会抛错() async {
        for (stop, expected) in [("refusal", LLMError.refusal), ("max_tokens", LLMError.truncated)] {
            let provider = ScriptedProvider([.success(ScriptedProvider.text("", stopReason: stop))])
            await #expect(throws: expected) {
                try await AgentLoop(provider: provider).run(system: "s", userMessage: "u", toolbox: AgentToolbox(context: Fixture.context()))
            }
        }
    }
}

struct ProviderTests {
    @Test func 请求体符合API约定() {
        let provider = AnthropicHTTPProvider(apiKey: "test")
        let body = provider.makeBody(LLMRequest(system: "sys", messages: [["role": "user", "content": "hi"]],
                                                tools: AgentToolbox.definitions, effort: "medium"))
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["thinking"] == ["type": "adaptive"])
        #expect(body["output_config"]?["effort"] == "medium")
        #expect(body["fallbacks"] == "default")
        #expect(body["tool_choice"] == ["type": "auto"])
        #expect(body["system"]?.array?.first?["cache_control"] == ["type": "ephemeral"])
        // No sampling parameters: rejected on this API version
        #expect(body["temperature"] == nil)

        let structured = provider.makeBody(LLMRequest(system: "s", messages: [], effort: "low", outputSchema: Schema.object([:])))
        #expect(structured["output_config"]?["format"]?["type"] == "json_schema")
        #expect(structured["tools"] == nil)
        #expect(structured["tool_choice"] == nil)
    }

    @Test func 整数不带小数点() {
        let value: JSONValue = ["n": 60, "x": .number(1.5)]
        #expect(value.jsonString == #"{"n":60,"x":1.5}"#)
    }
}

@MainActor
struct CaptureTests {
    @Test func 规则解析识别想法事件和目标() {
        let now = Fixture.now
        #expect(StructuredCalls.ruleCapture("明天下午3点 和老王聊预算 1小时 重要", now: now, calendar: Fixture.calendar).kind == .event)
        let event = StructuredCalls.ruleCapture("明天下午3点 和老王聊预算 1小时 重要", now: now, calendar: Fixture.calendar)
        #expect(event.start == Fixture.date(19, 15))
        #expect(event.priority == .important)
        #expect(event.category == .meeting)
        #expect(StructuredCalls.ruleCapture("研究一下个人网站方案", now: now, calendar: Fixture.calendar).kind == .idea)
        #expect(StructuredCalls.ruleCapture("本月目标：读完两本书", now: now, calendar: Fixture.calendar).goalPeriod == .month)
        #expect(StructuredCalls.ruleCapture("写年终总结", now: now, calendar: Fixture.calendar).isLarge)
    }

    @Test func AI解析结构化结果() async throws {
        let json = #"{"items":[{"title":"和老王聊预算","kind":"event","start":"2026-11-23T15:00:00+08:00","all_day":false,"minutes":30,"priority":"urgent","deadline":null,"category":"meeting","effort":"light","place":null,"goal_period":null,"is_large":false,"subtasks":[]}]}"#
        let provider = ScriptedProvider([.success(ScriptedProvider.text(json))])
        let result = try await StructuredCalls.capture("下周一下午找老王聊预算，挺急的", provider: provider, now: Fixture.now, calendar: Fixture.calendar)
        #expect(result.drafts == [CaptureDraft(title: "和老王聊预算", kind: .event, start: Fixture.date(23, 15), minutes: 30,
                                               priority: .urgent, category: .meeting, effort: .light)])
        #expect(provider.requests.first?.outputSchema != nil)
        #expect(provider.requests.first?.effort == "low")
    }

    @Test func 规则解析记忆() {
        let wednesday = StructuredCalls.ruleMemory("记住我周三晚上打球", now: Fixture.now)
        #expect(wednesday.kind == .rule)
        #expect(wednesday.constraint == MemoryConstraint(weekdays: [4], startMinute: 1140, endMinute: 1260))
        let lunch = StructuredCalls.ruleMemory("每天 12:00-13:30 午休", now: Fixture.now)
        #expect(lunch.constraint == MemoryConstraint(weekdays: Set(1...7), startMinute: 720, endMinute: 810))
        #expect(StructuredCalls.ruleMemory("我在做 iOS 版", now: Fixture.now).kind == .fact)
    }

    @Test func 日期解析容错() throws {
        #expect(try DateText.parse("2026-11-18T09:00:00+08:00") == Fixture.date(18, 9))
        #expect(try DateText.parse("2026-11-18T09:00+08:00") == Fixture.date(18, 9))
        #expect(try DateText.parse("2026-11-18T01:00:00.000Z") == Fixture.date(18, 9))
        #expect(throws: (any Error).self) { try DateText.parse("明天") }
    }
}

@MainActor
struct SecretaryTests {
    private func makeSecretary(tasks: [TaskSnapshot], provider: ScriptedProvider? = nil) -> (Secretary, TaskStore) {
        let repository = InMemoryTaskRepository(items: tasks, calendar: Fixture.calendar)
        let store = TaskStore(repository: repository)
        let engine = FocusEngine(taskStore: store, repository: InMemoryFocusSessionRepository(), notifier: RecordingNotifier(),
                                 dnd: NoopDoNotDisturbService(), clock: { Fixture.now })
        let defaults = UserDefaults(suiteName: "secretary-tests-\(UUID().uuidString)")!
        let ai = AISettings(defaults: defaults, secrets: InMemorySecretStore(), now: Fixture.now)
        if provider != nil { ai.saveKey("sk-test", consent: true) }
        let secretary = Secretary(taskStore: store, focusEngine: engine, memories: InMemoryMemoryRepository(), ai: ai,
                                  calendar: Fixture.calendar, providerFactory: { _ in provider ?? ScriptedProvider([]) })
        return (secretary, store)
    }

    @Test func 没有Key时用规则排期() async {
        let idea = Fixture.idea("看书", minutes: 45)
        let (secretary, _) = makeSecretary(tasks: [idea])
        #expect(!secretary.ai.isAvailable)
        let proposal = await secretary.planInbox(now: Fixture.now)
        #expect(proposal?.items.count == 1)
        #expect(proposal?.origin == .schedule)
    }

    @Test func AI失败时退回规则并提示() async {
        let idea = Fixture.idea("看书", minutes: 45)
        let (secretary, _) = makeSecretary(tasks: [idea], provider: ScriptedProvider([.failure(.invalidKey)]))
        #expect(secretary.ai.isAvailable)
        let proposal = await secretary.planInbox(now: Fixture.now)
        #expect(proposal?.items.count == 1)
        #expect(secretary.ai.isKeyInvalid)
        #expect(secretary.notice?.contains("API Key 无效") == true)
    }

    @Test func 应用后可以撤销() async {
        let idea = Fixture.idea("看书", minutes: 45)
        let (secretary, store) = makeSecretary(tasks: [idea])
        secretary.present(await secretary.planInbox(now: Fixture.now))
        #expect(secretary.applyActiveProposal() == 1)
        #expect(store.task(id: idea.id)?.kind == .event)
        #expect(secretary.activeProposal == nil)
        store.undo()
        #expect(store.task(id: idea.id)?.kind == .idea)
    }

    @Test func 截止日倒推分天并留出余量() {
        let task = Fixture.idea("季度方案", minutes: 240, deadline: Fixture.date(21, 18))
        let (secretary, _) = makeSecretary(tasks: [task])
        let proposal = secretary.backPlan(task, now: Fixture.now)
        let starts = proposal?.items.map(\.operation.sortDate) ?? []
        #expect(starts.count == 3) // 90 + 90 + 60
        #expect(Set(starts.map { Fixture.calendar.startOfDay(for: $0) }).count == 3)
        let ends = proposal?.items.compactMap { item -> Date? in
            switch item.operation { case .update(let t), .create(let t): t.end; default: nil }
        } ?? []
        #expect(ends.allSatisfy { $0 <= Fixture.date(21, 6) })
        #expect(proposal?.items.allSatisfy {
            switch $0.operation { case .update(let t), .create(let t): t.deadline == Fixture.date(21, 18); default: false }
        } == true)
    }

    @Test func 用量按月累计() {
        let defaults = UserDefaults(suiteName: "usage-\(UUID().uuidString)")!
        let ai = AISettings(defaults: defaults, secrets: InMemorySecretStore(), now: Fixture.now)
        var usage = LLMUsage()
        usage.inputTokens = 1000
        usage.outputTokens = 200
        ai.record(usage, now: Fixture.now)
        ai.record(usage, now: Fixture.now)
        #expect(ai.monthUsage.inputTokens == 2000)
        #expect(AISettings(defaults: defaults, secrets: InMemorySecretStore(), now: Fixture.now).monthUsage.outputTokens == 400)
        #expect(AISettings(defaults: defaults, secrets: InMemorySecretStore(), now: Fixture.date(18).addingTimeInterval(40 * 86400))
            .monthUsage.inputTokens == 0)
    }
}
