import Foundation
import Testing
@testable import Immerse

@MainActor
struct ProgressReminderTests {
    let clock = FakeClock()
    let notifier = RecordingNotifier()
    let taskStore = TaskStore(repository: InMemoryTaskRepository())
    let engine: FocusEngine
    let task: TaskSnapshot

    init() {
        let clock = self.clock
        engine = FocusEngine(taskStore: taskStore, repository: InMemoryFocusSessionRepository(),
                             notifier: notifier, dnd: NoopDoNotDisturbService(), clock: { clock.now },
                             progressMilestones: { [80, 50] })
        task = taskStore.create(TaskSnapshot(title: "阅读", start: clock.now,
                                             end: clock.now.addingTimeInterval(3600), isAllDay: false))
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func 开始后安排50和80的提醒() async {
        let start = clock.now
        engine.start(task)
        await settle()
        #expect(notifier.progress.map(\.percent) == [50, 80])
        #expect(notifier.progress.map(\.date) == [start.addingTimeInterval(30 * 60), start.addingTimeInterval(48 * 60)])
        #expect(notifier.progress.map(\.remainingSeconds) == [30 * 60, 12 * 60])
    }

    @Test func 暂停取消提醒继续后顺延() async {
        let start = clock.now
        engine.start(task)
        await settle()
        clock.advance(minutes: 10)
        engine.pause()
        #expect(notifier.progress.isEmpty)
        clock.advance(minutes: 5)
        engine.resume()
        #expect(notifier.progress.map(\.date) == [start.addingTimeInterval(35 * 60), start.addingTimeInterval(53 * 60)])
    }

    @Test func 已提醒过的进度延长后不再重复() async {
        engine.start(task)
        await settle()
        clock.advance(minutes: 35)
        engine.tick()
        engine.extend()   // plan becomes 75 minutes: 50% is at 37.5 minutes, but it was already reminded
        #expect(notifier.progress.map(\.percent) == [80])
    }

    @Test func 时间到和结束时取消提醒() async {
        engine.start(task)
        await settle()
        engine.finishEarly()
        #expect(notifier.progress.isEmpty)
    }
}

@MainActor
struct UnsavedDraftTests {
    let store = CalendarStore()
    let draft = DraftEvent(start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_003_600))

    @Test func 没填内容不保留() {
        store.keepUnsaved(TaskSnapshot(title: "  ", start: draft.start, end: draft.end, isAllDay: false))
        #expect(store.unsavedDraft == nil)
        #expect(store.makeNewTask(for: draft).isRestored == false)
    }

    @Test func 填了内容下次恢复且时间用新选的() {
        store.keepUnsaved(TaskSnapshot(title: "写周报", start: .distantPast, end: nil, isAllDay: true, priority: .urgent))
        let (task, restored) = store.makeNewTask(for: draft)
        #expect(restored)
        #expect(task.title == "写周报")
        #expect(task.priority == .urgent)
        #expect(task.start == draft.start && task.end == draft.end && !task.isAllDay)
    }

    @Test func 默认时间打开时连时间一起恢复() {
        let saved = TaskSnapshot(title: "写周报", start: draft.start.addingTimeInterval(7200),
                                 end: draft.end.addingTimeInterval(7200), isAllDay: false)
        store.keepUnsaved(saved)
        var defaultDraft = draft
        defaultDraft.usesDefaultTime = true
        #expect(store.makeNewTask(for: defaultDraft).task.start == saved.start)
    }
}

struct DailyReviewTests {
    private let calendar = Calendar.app

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func 下一次提醒时间() {
        #expect(DailyReview.nextFireDate(after: date(18, 9), minutes: 21 * 60, calendar: calendar) == date(18, 21))
        #expect(DailyReview.nextFireDate(after: date(18, 21), minutes: 21 * 60, calendar: calendar) == date(19, 21))
        #expect(DailyReview.nextFireDate(after: date(18, 22), minutes: 21 * 60 + 30, calendar: calendar) == date(19, 21, 30))
    }

    @Test func 列出没完成的任务() {
        let tasks = [
            TaskSnapshot(title: "健身", start: date(18, 19), end: date(18, 20), isAllDay: false),
            TaskSnapshot(title: "阅读", start: date(18, 9), end: date(18, 10), isAllDay: false),
            TaskSnapshot(title: "周会", start: date(18, 14), end: date(18, 15), isAllDay: false, status: .done),
            TaskSnapshot(title: "黑客松", start: date(18, 0), end: nil, isAllDay: true),
        ]
        let content = DailyReview.content(for: tasks, calendar: calendar)
        #expect(content?.title == "今天还有 3 个任务没完成")
        #expect(content?.body == "· 全天  黑客松\n· 09:00  阅读\n· 19:00  健身")
    }

    @Test func 超过五个只列前五个() {
        let tasks = (0..<7).map { TaskSnapshot(title: "任务\($0)", start: date(18, 8 + $0), end: nil, isAllDay: false) }
        #expect(DailyReview.content(for: tasks, calendar: calendar)?.body.hasSuffix("…还有 2 个") == true)
    }

    @Test func 全部完成和没有任务() {
        let done = [TaskSnapshot(title: "阅读", start: date(18, 9), end: nil, isAllDay: false, status: .done)]
        #expect(DailyReview.content(for: done, calendar: calendar)?.title == "今天的任务全部完成 🎉")
        #expect(DailyReview.content(for: [], calendar: calendar) == nil)
    }
}
