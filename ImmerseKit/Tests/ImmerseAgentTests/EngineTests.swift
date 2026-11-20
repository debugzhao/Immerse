import Foundation
import ImmerseCore
import Testing
@testable import ImmerseAgent

struct SlotFinderTests {
    @Test func 空档避开日程会议和记忆规则() {
        let meeting = ExternalEvent(id: "m", title: "周会", start: Fixture.date(18, 10), end: Fixture.date(18, 11), isAllDay: false)
        let rule = MemoryConstraint(weekdays: [4], startMinute: 19 * 60, endMinute: 21 * 60) // Wednesday evening
        let context = Fixture.context(tasks: [Fixture.event("写方案", 18, 14, minutes: 120)], external: [meeting], constraints: [rule])
        let slots = SlotFinder.freeSlots(in: DateInterval(start: Fixture.date(18), end: Fixture.date(19)), context: context)
        #expect(slots.map(\.interval) == [
            DateInterval(start: Fixture.date(18, 9), end: Fixture.date(18, 10)),
            DateInterval(start: Fixture.date(18, 11), end: Fixture.date(18, 14)),
            DateInterval(start: Fixture.date(18, 16), end: Fixture.date(18, 19)),
            DateInterval(start: Fixture.date(18, 21), end: Fixture.date(18, 22)),
        ])
    }

    @Test func 不会给出过去的时间() {
        let context = Fixture.context(now: Fixture.date(18, 15, 7))
        let slots = SlotFinder.freeSlots(in: DateInterval(start: Fixture.date(18), end: Fixture.date(19)), context: context)
        #expect(slots.first?.interval.start == Fixture.date(18, 15, 15))
    }

    @Test func 完成的日程不占时间() {
        let context = Fixture.context(tasks: [Fixture.event("已完成", 18, 9, minutes: 600, status: .done)])
        let slots = SlotFinder.freeSlots(in: DateInterval(start: Fixture.date(18), end: Fixture.date(19)), context: context)
        #expect(slots.map(\.interval) == [DateInterval(start: Fixture.date(18, 9), end: Fixture.date(18, 22))])
    }
}

struct EnergyCurveTests {
    @Test func 没有数据时用通用曲线() {
        let curve = EnergyCurve.from(records: [], calendar: Fixture.calendar)
        #expect(curve == .generic)
        #expect(!curve.isPersonalized)
        #expect(curve.peakHours() == [9, 10, 11])
    }

    @Test func 足够的数据后高效时段变成用户自己的() {
        let records = (1...12).map { Fixture.record(nil, day: $0, hour: 20, minutes: 60) }
        let curve = EnergyCurve.from(records: records, calendar: Fixture.calendar)
        #expect(curve.isPersonalized)
        #expect(curve.peakHours(count: 1) == [20])
        #expect(curve.hourly[20] > curve.hourly[10])
    }
}

struct SchedulerTests {
    @Test func 截止早的先排而且在截止前() {
        let urgent = Fixture.idea("交周报", minutes: 60, deadline: Fixture.date(18, 12))
        let later = Fixture.idea("看书", minutes: 60)
        let context = Fixture.context(tasks: [urgent, later])
        let slots = SlotFinder.freeSlots(in: DateInterval(start: Fixture.date(18), end: Fixture.date(20)), context: context)
        let result = Scheduler.plan([later, urgent], into: slots, context: context)
        guard case .update(let first) = result.items.first?.operation else { Issue.record("no first item"); return }
        #expect(first.id == urgent.id)
        #expect(first.end! <= Fixture.date(18, 12))
        #expect(first.kind == .event)
        #expect(result.items.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func 难的任务放进高效时段() {
        let hard = Fixture.idea("写架构设计", minutes: 90, effort: .hard)
        // Earliest gap is 13:00–14:00 (low energy); a 9:00–12:00 morning slot exists tomorrow
        let context = Fixture.context(tasks: [hard, Fixture.event("占位", 18, 9, minutes: 240)], now: Fixture.date(18, 13))
        let slots = SlotFinder.freeSlots(in: DateInterval(start: Fixture.date(18), end: Fixture.date(20)), context: context)
        let result = Scheduler.plan([hard], into: slots, context: context)
        guard case .update(let placed) = result.items.first?.operation else { Issue.record("not placed"); return }
        #expect(Fixture.calendar.component(.hour, from: placed.start) == 9)
        #expect(result.items.first?.reason.contains("精力") == true)
    }

    @Test func 长任务拆块分天() {
        #expect(Scheduler.blocks(for: 150) == [90, 60])
        #expect(Scheduler.blocks(for: 60) == [60])
        let big = Fixture.idea("写年终总结", minutes: 180)
        let context = Fixture.context(tasks: [big])
        let slots = SlotFinder.freeSlots(in: DateInterval(start: Fixture.date(18), end: Fixture.date(22)), context: context)
        let result = Scheduler.plan([big], into: slots, context: context)
        #expect(result.items.count == 2)
        let days = Set(result.items.map { Fixture.calendar.startOfDay(for: $0.operation.sortDate) })
        #expect(days.count == 2)
        guard case .create(let second) = result.items[1].operation else { Issue.record("second part"); return }
        #expect(second.parentID == big.id)
        #expect(second.title == "写年终总结（2/2）")
    }

    @Test func 放不下的任务列为未安排() {
        let task = Fixture.idea("看书", minutes: 60)
        let context = Fixture.context(tasks: [task])
        let result = Scheduler.plan([task], into: [], context: context)
        #expect(result.items.isEmpty)
        #expect(result.unplaced.map(\.id) == [task.id])
    }

    @Test func 接受的估时系数会放大时长() {
        let task = Fixture.idea("读论文", minutes: 60, category: .reading)
        let context = Fixture.context(tasks: [task], multipliers: [.reading: 1.6])
        #expect(context.estimatedMinutes(for: task) == 100)
    }
}

struct ReflowTests {
    @Test func 被打断后顺延剩下的日程() {
        let a = Fixture.event("A", 18, 10)
        let b = Fixture.event("B", 18, 11)
        let offsite = Fixture.event("外出", 18, 13, place: "公司")
        let context = Fixture.context(tasks: [a, b, offsite], now: Fixture.date(18, 10, 40))
        let proposal = Reflow.plan(day: Fixture.date(18), from: Fixture.date(18, 10, 40), context: context)
        let moves = proposal?.items.compactMap { item -> (UUID, Date)? in
            if case .move(let id, let start, _) = item.operation { return (id, start) } else { return nil }
        } ?? []
        // A (missed) moves to 10:45, B to 11:45; the off-site event stays at 13:00
        #expect(moves.map(\.0) == [a.id, b.id])
        #expect(moves.map(\.1) == [Fixture.date(18, 10, 45), Fixture.date(18, 11, 45)])
    }

    @Test func 绕过固定日程() {
        let a = Fixture.event("A", 18, 12)
        let fixed = Fixture.event("体检", 18, 12, 30, minutes: 60, place: "医院")
        let context = Fixture.context(tasks: [a, fixed], now: Fixture.date(18, 12, 10))
        let proposal = Reflow.plan(day: Fixture.date(18), from: Fixture.date(18, 12, 10), context: context)
        guard case .move(_, let start, _)? = proposal?.items.first?.operation else { Issue.record("no move"); return }
        #expect(start == Fixture.date(18, 13, 30))
    }

    @Test func 当天放不下的挪到明天() {
        let late = Fixture.event("晚间任务", 18, 21)
        let context = Fixture.context(tasks: [late], now: Fixture.date(18, 21, 30))
        let proposal = Reflow.plan(day: Fixture.date(18), from: Fixture.date(18, 21, 30), context: context)
        guard case .move(let id, let start, _)? = proposal?.items.first?.operation else { Issue.record("no move"); return }
        #expect(id == late.id)
        #expect(Fixture.calendar.isDate(start, inSameDayAs: Fixture.date(19)))
        #expect(proposal?.items.first?.reason.contains("明天") == true)
    }

    @Test func 没有被影响时不提案() {
        let context = Fixture.context(tasks: [Fixture.event("A", 18, 15)], now: Fixture.date(18, 10))
        #expect(Reflow.plan(day: Fixture.date(18), from: Fixture.date(18, 10), context: context) == nil)
    }
}

struct InsightTests {
    @Test func 历史不足时用默认容量() {
        let load = LoadEstimator.load(on: Fixture.date(18), context: Fixture.context(tasks: [Fixture.event("A", 18, 9, minutes: 600)]))
        #expect(load.capacityMinutes == LoadEstimator.defaultCapacityMinutes)
        #expect(!load.capacityIsPersonal)
        #expect(load.overloadMinutes == 240)
        #expect(load.isOverloaded)
    }

    @Test func 容量取最近有专注的日子的P75() {
        let minutes = [100, 200, 300, 400, 500, 600]
        let records = minutes.enumerated().map { Fixture.record(nil, day: 10 + $0.offset, hour: 9, minutes: $0.element) }
        let capacity = LoadEstimator.capacity(records: records, now: Fixture.now, calendar: Fixture.calendar)
        #expect(capacity.isPersonal)
        #expect(capacity.minutes == 500)
    }

    @Test func 过载时建议挪走最不重要最晚的() {
        let important = Fixture.event("重要", 18, 9, minutes: 240, priority: .important)
        let normalEarly = Fixture.event("普通早", 18, 14, minutes: 120)
        let normalLate = Fixture.event("普通晚", 18, 17, minutes: 120)
        let context = Fixture.context(tasks: [important, normalEarly, normalLate])
        let load = LoadEstimator.load(on: Fixture.date(18), context: context)
        #expect(LoadEstimator.deferrals(for: load, context: context).map(\.title) == ["普通晚"])
    }

    @Test func 截止风险三种情况() {
        let late = TaskSnapshot(title: "排晚了", start: Fixture.date(21, 10), end: Fixture.date(21, 11), isAllDay: false,
                                deadline: Fixture.date(20, 18))
        let overdue = Fixture.idea("过期", minutes: 30, deadline: Fixture.date(17, 18))
        let tight = Fixture.idea("来不及", minutes: 600, deadline: Fixture.date(18, 12))
        let fine = Fixture.idea("来得及", minutes: 60, deadline: Fixture.date(22, 18))
        let risks = DeadlineRisk.assess(context: Fixture.context(tasks: [late, overdue, tight, fine]))
        #expect(Dictionary(uniqueKeysWithValues: risks.map { ($0.task.title, $0.kind) })
                == ["排晚了": .scheduledTooLate, "过期": .overdue, "来不及": .notEnoughTime])
        #expect(risks.first { $0.task.title == "排晚了" }?.delayDays == 1)
    }

    @Test func 估时校准需要足够样本() {
        var tasks: [TaskSnapshot] = []
        var records: [FocusRecord] = []
        for index in 0..<5 {
            let task = Fixture.event("读书\(index)", 10 + index, 9, minutes: 60, status: .done, category: .reading)
            tasks.append(task)
            records.append(Fixture.record(task, day: 10 + index, hour: 9, minutes: 96))
        }
        let insights = Calibration.insights(tasks: tasks, records: records)
        #expect(insights.map(\.category) == [.reading])
        #expect(insights.first?.suggestedMultiplier == 1.6)
        #expect(insights.first?.message.contains("超时 60%") == true)
        #expect(Calibration.insights(tasks: Array(tasks.prefix(4)), records: records).isEmpty)
        // Already accepted → quiet
        #expect(Calibration.insights(tasks: tasks, records: records, accepted: [.reading: 1.6]).isEmpty)
    }

    @Test func 目标节奏() {
        let cadence = GoalBreakdown.cadence(targetMinutes: 600, focusedMinutes: 0, now: Fixture.date(1), periodEnd: Fixture.date(29),
                                            calendar: Fixture.calendar)
        #expect(cadence == GoalCadence(remainingMinutes: 600, weeks: 4, sessionsPerWeek: 3, minutesPerSession: 50))
        #expect(GoalBreakdown.cadence(targetMinutes: 60, focusedMinutes: 90, now: Fixture.date(1), periodEnd: Fixture.date(29),
                                      calendar: Fixture.calendar) == nil)
    }

    @Test func 目标安排每天最多一次并关联目标() {
        let goal = TaskSnapshot(title: "读完两本书", start: Fixture.date(16), end: Fixture.date(22), isAllDay: true, kind: .goal)
        let cadence = GoalCadence(remainingMinutes: 150, weeks: 1, sessionsPerWeek: 3, minutesPerSession: 50)
        let proposal = GoalBreakdown.plan(goal: goal, cadence: cadence, context: Fixture.context(tasks: [goal]))
        let tasks = proposal?.items.compactMap { item -> TaskSnapshot? in if case .create(let task) = item.operation { task } else { nil } } ?? []
        #expect(tasks.count == 3)
        #expect(Set(tasks.map { Fixture.calendar.startOfDay(for: $0.start) }).count == 3)
        #expect(tasks.allSatisfy { $0.goalID == goal.id && $0.plannedMinutes == 50 })
    }

    @Test func 专注前简报() {
        var task = Fixture.event("写方案", 18, 9, category: .writing)
        task.notes = "背景\n- [ ] 补充竞品数据\n- [x] 列提纲\n- [ ] 画架构图"
        let last = Fixture.record(task, day: 17, hour: 14, minutes: 45, reason: .finishedEarly)
        let briefing = Briefing.beforeFocus(on: task, context: Fixture.context(tasks: [task], records: [last]))
        #expect(briefing.openTodos == ["补充竞品数据", "画架构图"])
        #expect(briefing.lastSession?.focusedSeconds == 45 * 60)
        #expect(briefing.estimateNote == nil)
    }

    @Test func 关键词分类和大任务判断() {
        #expect(CategoryGuesser.guess("和老王聊预算") == .meeting)
        #expect(CategoryGuesser.guess("读《原则》") == .reading)
        #expect(CategoryGuesser.guess("晚上去健身") == .exercise)
        #expect(CategoryGuesser.looksLarge("写年终总结", minutes: nil))
        #expect(!CategoryGuesser.looksLarge("回复邮件", minutes: 20))
    }
}
