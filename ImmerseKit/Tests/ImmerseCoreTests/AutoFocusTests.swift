import Foundation
import Testing
@testable import ImmerseCore

/// Records auto-focus notifications instead of sending them
@MainActor
final class RecordingAutoFocusNotifier: AutoFocusNotifying {
    private(set) var upcoming: [(taskID: UUID, fire: Date)] = []
    private(set) var upcomingCancelCount = 0
    private(set) var started: [(taskID: UUID, seconds: Int)] = []
    private(set) var conflicts: [UUID] = []

    func requestAuthorizationIfNeeded() async {}
    func scheduleAutoFocusUpcoming(taskID: UUID, title: String, start: Date, at date: Date) { upcoming.append((taskID, date)) }
    func cancelAutoFocusUpcoming() { upcomingCancelCount += 1 }
    func postAutoFocusStarted(taskID: UUID, title: String, plannedSeconds: Int) { started.append((taskID, plannedSeconds)) }
    func postAutoFocusConflict(taskID: UUID, title: String, currentTitle: String) { conflicts.append(taskID) }
}

@MainActor
struct AutoFocusTests {
    let clock = FakeClock()
    let defaults: UserDefaults
    let settings: SettingsStore
    let taskStore = TaskStore(repository: InMemoryTaskRepository())
    let engine: FocusEngine
    let notifier = RecordingAutoFocusNotifier()
    let scheduler: AutoFocusScheduler
    /// 30 minutes from the test's "now", one hour long
    let meeting: TaskSnapshot

    init() {
        let name = "immerse.tests.autofocus.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        settings = SettingsStore(defaults: defaults)
        let clock = self.clock
        engine = FocusEngine(taskStore: taskStore, repository: InMemoryFocusSessionRepository(),
                             notifier: RecordingNotifier(), dnd: FakeDoNotDisturb(), clock: { clock.now })
        scheduler = AutoFocusScheduler(taskStore: taskStore, focusEngine: engine, settings: settings, notifier: notifier,
                                       defaults: defaults, clock: { clock.now })
        meeting = taskStore.create(TaskSnapshot(title: "周会", start: clock.now.addingTimeInterval(30 * 60),
                                                end: clock.now.addingTimeInterval(90 * 60), isAllDay: false))
    }

    private func makeScheduler() -> AutoFocusScheduler {
        let clock = self.clock
        return AutoFocusScheduler(taskStore: taskStore, focusEngine: engine, settings: settings, notifier: notifier,
                                  defaults: defaults, clock: { clock.now })
    }

    private func event(_ title: String, startIn minutes: Double, length: Double, planned: Int? = nil,
                       kind: TaskKind = .event, isAllDay: Bool = false, status: TaskStatus = .todo) -> TaskSnapshot {
        let start = clock.now.addingTimeInterval(minutes * 60)
        var task = TaskSnapshot(title: title, start: start, end: start.addingTimeInterval(length * 60), isAllDay: isAllDay)
        task.plannedMinutes = planned
        task.kind = kind
        task.status = status
        return taskStore.create(task)
    }

    @Test func 到点前不开始只排一条开始前一分钟的系统通知() {
        scheduler.evaluate()
        #expect(engine.session == nil)
        #expect(notifier.upcoming.count == 1)
        #expect(notifier.upcoming.first?.taskID == meeting.id)
        #expect(notifier.upcoming.first?.fire == meeting.start.addingTimeInterval(-60))

        // Checking again doesn't queue the same notification twice
        clock.advance(minutes: 5)
        scheduler.evaluate()
        #expect(notifier.upcoming.count == 1)
    }

    @Test func 到点自动开始专注并转为进行中() {
        clock.advance(minutes: 30)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: meeting.id))
        #expect(engine.phase == .running)
        #expect(engine.remaining == 60 * 60)
        #expect(taskStore.task(id: meeting.id)?.status == .inProgress)
        #expect(notifier.started.map(\.taskID) == [meeting.id])
        #expect(notifier.started.first?.seconds == 3600)
    }

    @Test func 设了计划时长时按计划时长() {
        let review = event("复盘", startIn: 10, length: 60, planned: 25)
        clock.advance(minutes: 10)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: review.id))
        #expect(engine.remaining == 25 * 60)
    }

    @Test func 错过开始时间补上时按剩余时间算() {
        // App was closed / Mac asleep: comes back 20 minutes into the meeting
        clock.advance(minutes: 50)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: meeting.id))
        #expect(engine.remaining == 40 * 60)
    }

    @Test func 补上时计划时长不超过日程结束() {
        let review = event("复盘", startIn: 0, length: 30, planned: 60)
        clock.advance(minutes: 20)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: review.id))
        #expect(engine.remaining == 10 * 60)
    }

    @Test func 日程已结束不再补() {
        clock.advance(minutes: 90)
        scheduler.evaluate()
        #expect(engine.session == nil)
        #expect(notifier.started.isEmpty)
    }

    @Test func 全天事件和已完成的日程不触发() {
        _ = event("全天", startIn: -60, length: 24 * 60, isAllDay: true)
        _ = event("做完了", startIn: -5, length: 60, status: .done)
        scheduler.evaluate()
        #expect(engine.session == nil)
    }

    @Test func 放弃后不会再次自动开始() {
        clock.advance(minutes: 30)
        scheduler.evaluate()
        engine.abandon()
        clock.advance(minutes: 1)
        scheduler.evaluate()
        #expect(engine.session == nil)
        #expect(notifier.started.count == 1)
    }

    @Test func 处理记录持久化重启后不重复开始() {
        clock.advance(minutes: 30)
        scheduler.evaluate()
        engine.abandon()

        let relaunched = makeScheduler()
        relaunched.evaluate()
        #expect(engine.session == nil)
    }

    @Test func 日程被挪动后重新参与() {
        clock.advance(minutes: 30)
        scheduler.evaluate()
        engine.abandon()
        var moved = taskStore.task(id: meeting.id)!
        moved.start = clock.now.addingTimeInterval(10 * 60)
        moved.end = moved.start.addingTimeInterval(30 * 60)
        taskStore.update(moved)
        clock.advance(minutes: 10)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: meeting.id))
    }

    @Test func 有专注在进行时不打断但转为进行中并询问() {
        let reading = event("阅读", startIn: 0, length: 120)
        engine.start(reading)
        clock.advance(minutes: 30)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: reading.id))
        #expect(taskStore.task(id: meeting.id)?.status == .inProgress)
        #expect(notifier.conflicts == [meeting.id])

        scheduler.handle(.switchFocus, taskID: meeting.id)
        #expect(engine.isFocusing(on: meeting.id))
        #expect(engine.remaining == 60 * 60)
    }

    @Test func 推迟五分钟() {
        clock.advance(minutes: 29)
        scheduler.handle(.snooze, taskID: meeting.id)
        clock.advance(minutes: 1)
        scheduler.evaluate()
        #expect(engine.session == nil)

        clock.advance(minutes: 5)
        scheduler.evaluate()
        #expect(engine.isFocusing(on: meeting.id))
        #expect(engine.remaining == 55 * 60)
    }

    @Test func 跳过后到点不开始() {
        clock.advance(minutes: 29)
        scheduler.handle(.skip, taskID: meeting.id)
        clock.advance(minutes: 1)
        scheduler.evaluate()
        #expect(engine.session == nil)
        #expect(taskStore.task(id: meeting.id)?.status == .todo)
    }

    @Test func 通知上放弃本次() {
        clock.advance(minutes: 30)
        scheduler.evaluate()
        scheduler.handle(.abandon, taskID: meeting.id)
        #expect(engine.session == nil)
        #expect(taskStore.task(id: meeting.id)?.status == .todo)
    }

    @Test func 关闭开关后不自动开始() {
        settings.autoFocusEnabled = false
        clock.advance(minutes: 30)
        scheduler.evaluate()
        #expect(engine.session == nil)
        #expect(notifier.upcoming.isEmpty)
    }

    @Test func 默认开启自动专注() {
        #expect(settings.autoFocusEnabled)
    }
}
