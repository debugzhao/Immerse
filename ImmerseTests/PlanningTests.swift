import Foundation
import ImmerseCore
import Testing
@testable import Immerse

@MainActor
struct PlanningTests {
    let calendar = Calendar.app
    let repository = InMemoryTaskRepository()
    let store: TaskStore

    init() { store = TaskStore(repository: repository) }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func 想法不出现在日历上() {
        store.captureIdea("找全球工作的 Agent", now: date(19, 10))
        #expect(store.ideas().map(\.title) == ["找全球工作的 Agent"])
        #expect(store.tasks(in: DateInterval(start: date(1), end: date(30))).isEmpty)
        #expect(store.captureIdea("   ") == nil)
    }

    @Test func 拖动调整收集箱顺序() {
        let a = store.captureIdea("A", now: date(19, 10))!
        let b = store.captureIdea("B", now: date(19, 11))!
        let c = store.captureIdea("C", now: date(19, 12))!
        #expect(store.ideas().map(\.title) == ["C", "B", "A"])   // newest first by default

        // Drag C down onto A: C takes A's place at the bottom
        let order = TaskStore.reordered(store.ideas().map(\.id), moving: c.id, onto: a.id)!
        store.reorder(order)
        #expect(store.ideas().map(\.title) == ["B", "A", "C"])

        // A fresh idea still lands on top of the hand-made order
        store.captureIdea("D", now: date(19, 13))
        #expect(store.ideas().map(\.title) == ["D", "B", "A", "C"])

        // Drag A up onto B: A takes B's place
        store.reorder(TaskStore.reordered(store.ideas().map(\.id), moving: a.id, onto: b.id)!)
        #expect(store.ideas().map(\.title) == ["D", "A", "B", "C"])

        store.undo()
        #expect(store.ideas().map(\.title) == ["D", "B", "A", "C"])
        #expect(TaskStore.reordered([a.id, b.id], moving: a.id, onto: a.id) == nil)
        #expect(TaskStore.reordered([a.id], moving: b.id, onto: a.id) == nil)
    }

    @Test func 拖动调整目标顺序且新目标排在未完成末尾() {
        // Default order is by end date: the week goal A before the month goal B
        let a = store.createGoal("A", period: .week, calendar: calendar)!
        let b = store.createGoal("B", period: .month, calendar: calendar)!
        let goals = { GoalsSection.activeGoals(taskStore: store, calendar: calendar) }
        let active = { goals().map(\.title) }
        #expect(active() == ["A", "B"])
        store.reorder(TaskStore.reordered(goals().map(\.id), moving: b.id, onto: a.id)!)
        #expect(active() == ["B", "A"])

        store.createGoal("C", period: .week, calendar: calendar)
        #expect(active() == ["B", "A", "C"])

        // Goals that are done still sink to the bottom
        store.toggleDone(b.id)
        #expect(active() == ["A", "C", "B"])
    }

    @Test func 列表超过六条折叠() {
        #expect(collapsedRows(Array(1...8), isExpanded: false) == Array(1...6))
        #expect(collapsedRows(Array(1...8), isExpanded: true) == Array(1...8))
        #expect(collapsedRows(Array(1...3), isExpanded: false) == Array(1...3))
    }

    @Test func 本周和本月的范围() {
        let week = GoalPeriod.week.range(containing: date(19, 15), calendar: calendar)
        #expect(week.start == date(16) && week.lastDay == date(22))
        let month = GoalPeriod.month.range(containing: date(19, 15), calendar: calendar)
        #expect(month.start == date(1) && month.lastDay == date(30))
    }

    @Test func 想法拖进日历变成日程() {
        let idea = store.captureIdea("找全球工作的 Agent", now: date(19))!
        let event = store.schedule(idea.id, at: date(20, 14), calendar: calendar)
        #expect(event?.kind == .event)
        #expect(event?.end == date(20, 15))
        #expect(store.ideas().isEmpty)
        #expect(store.tasks(in: DateInterval(start: date(20), end: date(21))).map(\.id) == [idea.id])
        store.undo()
        #expect(store.ideas().count == 1)
    }

    @Test func 目标拖进日历生成关联日程目标本身保留() {
        let goal = store.createGoal("读完《纳瓦尔宝典》", period: .month, now: date(19), calendar: calendar)!
        let session = store.schedule(goal.id, at: date(20, 20), calendar: calendar)!
        #expect(session.id != goal.id)
        #expect(session.goalID == goal.id)
        #expect(session.title == "读完《纳瓦尔宝典》")
        #expect(store.goals().map(\.id) == [goal.id])
        #expect(store.events(linkedTo: goal.id).map(\.id) == [session.id])
    }

    @Test func 想法升级为目标再移回收集箱() {
        let idea = store.captureIdea("学 SwiftUI 动画", now: date(19))!
        store.makeGoal(idea.id, period: .week, now: date(19), calendar: calendar)
        #expect(store.goals().first?.start == date(16))
        #expect(store.goals().first?.end == date(22))
        store.moveToInbox(idea.id, now: date(19))
        #expect(store.goals().isEmpty && store.ideas().count == 1)
    }
}

struct GoalProgressTests {
    let calendar = Calendar.app

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func record(_ taskID: UUID, minutes: Int, day: Int) -> FocusRecord {
        FocusRecord(id: UUID(), taskID: taskID, taskTitle: "", startedAt: date(day, 20),
                    endedAt: date(day, 20).addingTimeInterval(TimeInterval(minutes * 60)),
                    focusedSeconds: minutes * 60, reason: .completed)
    }

    let goal: TaskSnapshot

    init() {
        goal = TaskSnapshot(title: "读书",
                            start: Calendar.app.date(from: DateComponents(year: 2026, month: 11, day: 1))!,
                            end: Calendar.app.date(from: DateComponents(year: 2026, month: 11, day: 30))!,
                            isAllDay: true, kind: .goal, targetMinutes: 600)
    }

    @Test func 专注时长计入目标进度() {
        let session = TaskSnapshot(title: "读书", start: date(18, 20), end: nil, isAllDay: false, status: .done, goalID: goal.id)
        let other = UUID()
        let progress = GoalProgress(goal: goal, linkedEvents: [session],
                                    records: [record(session.id, minutes: 120, day: 18), record(goal.id, minutes: 60, day: 19),
                                              record(other, minutes: 300, day: 19)],
                                    now: date(19, 12), calendar: calendar)
        #expect(progress.focusedMinutes == 180)
        #expect(progress.percent == 30)
        #expect(progress.completedCount == 1)
        #expect(progress.daysLeft == 12)
        #expect(progress.isBehind)   // 30% done, ~60% of the month gone
    }

    @Test func 没有目标时长时按完成次数() {
        var goal = self.goal
        goal.targetMinutes = nil
        let events = [true, false, true, true].map {
            TaskSnapshot(title: "健身", start: date(10), end: nil, isAllDay: false, status: $0 ? .done : .todo, goalID: goal.id)
        }
        let progress = GoalProgress(goal: goal, linkedEvents: events, records: [], now: date(19), calendar: calendar)
        #expect(progress.percent == 75)
        #expect(progress.summary == "完成 3 / 4 次")
        #expect(!progress.isBehind)
    }
}

@MainActor
struct GoalFocusTests {
    @Test func 专注目标本身不改变目标状态() {
        let store = TaskStore(repository: InMemoryTaskRepository())
        let engine = FocusEngine(taskStore: store, repository: InMemoryFocusSessionRepository(),
                                 notifier: RecordingNotifier(), dnd: NoopDoNotDisturbService())
        let goal = store.createGoal("读完《纳瓦尔宝典》", period: .month)!
        engine.start(goal)
        #expect(store.task(id: goal.id)?.status == .todo)
        engine.finishEarly()
        #expect(store.task(id: goal.id)?.status == .todo)
    }
}

struct PlanningInputTests {
    @Test func 识别目标前缀() {
        #expect(PlanningInput.goal(from: "本月目标：读完《纳瓦尔宝典》")?.title == "读完《纳瓦尔宝典》")
        #expect(PlanningInput.goal(from: "本周目标 健身 3 次")?.period == .week)
        #expect(PlanningInput.goal(from: "目标:学 Swift")?.period == .month)
        #expect(PlanningInput.goal(from: "明天下午3点 阅读") == nil)
        #expect(PlanningInput.goal(from: "本月目标") == nil)
    }

    @Test func 识别想法前缀() {
        #expect(PlanningInput.isExplicitIdea("想法：找全球工作的 Agent"))
        #expect(PlanningInput.idea(from: "想法：找全球工作的 Agent") == "找全球工作的 Agent")
        #expect(PlanningInput.idea(from: "找全球工作的 Agent") == "找全球工作的 Agent")
        #expect(!PlanningInput.isExplicitIdea("想法"))
    }
}

struct DailyReviewGoalTests {
    @Test func 复盘附上落后的目标() {
        let calendar = Calendar.app
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9))!
        let tasks = [TaskSnapshot(title: "阅读", start: day, end: nil, isAllDay: false)]
        let content = DailyReview.content(for: tasks, behindGoals: ["读完《纳瓦尔宝典》 30%"], calendar: calendar)
        #expect(content?.body.hasSuffix("进度落后的目标：\n· 读完《纳瓦尔宝典》 30%") == true)
        #expect(DailyReview.content(for: [], behindGoals: ["读书 10%"], calendar: calendar)?.title == "有 1 个目标进度落后")
        #expect(DailyReview.content(for: [], behindGoals: [], calendar: calendar) == nil)
    }
}
