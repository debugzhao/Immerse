import Foundation
import Testing
@testable import ImmerseCore

/// A clock that tests can advance manually
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

/// A fake Do Not Disturb service that records call order
@MainActor
final class FakeDoNotDisturb: DoNotDisturbServicing {
    var isEnabledInSettings = true
    private(set) var isActivatedByApp = false
    private(set) var log: [String] = []
    var shouldFail = false

    func activate() async throws {
        if shouldFail { throw URLError(.cannotConnectToHost) }
        isActivatedByApp = true
        log.append("on")
    }

    func deactivate() async throws {
        isActivatedByApp = false
        log.append("off")
    }

    /// Simulates a previous crash that left Do Not Disturb on
    func simulateLeftOn() { isActivatedByApp = true }
}

@MainActor
struct FocusEngineTests {
    let clock = FakeClock()
    let tasks = InMemoryTaskRepository()
    let sessions = InMemoryFocusSessionRepository()
    let notifier = RecordingNotifier()
    let dnd = FakeDoNotDisturb()
    let taskStore: TaskStore
    let engine: FocusEngine
    let task: TaskSnapshot

    init() {
        taskStore = TaskStore(repository: tasks)
        let clock = self.clock
        engine = FocusEngine(taskStore: taskStore, repository: sessions, notifier: notifier,
                             dnd: dnd, clock: { clock.now })
        task = taskStore.create(TaskSnapshot(title: "阅读《第一性原理》", start: clock.now,
                                             end: clock.now.addingTimeInterval(3600), isAllDay: false))
    }

    /// Lets the async Tasks spawned by the engine (toggling DND, sending notifications) finish
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func 开始后任务变为进行中并开启勿扰() async {
        engine.start(task)
        await settle()
        #expect(engine.phase == .running)
        #expect(taskStore.task(id: task.id)?.status == .inProgress)
        #expect(engine.remaining == 3600)
        #expect(dnd.log == ["on"])
        #expect(notifier.backups.count == 1)
    }

    @Test func 计时只依赖时间戳() {
        engine.start(task)
        clock.advance(minutes: 25)
        engine.tick()
        #expect(engine.remaining == 35 * 60)
        #expect(engine.remainingText == "35:00")
    }

    @Test func 暂停期间不计时() {
        engine.start(task)
        clock.advance(minutes: 10)
        engine.pause()
        clock.advance(minutes: 30)
        engine.tick()
        #expect(engine.remaining == 50 * 60)
        engine.resume()
        clock.advance(minutes: 5)
        engine.tick()
        #expect(engine.remaining == 45 * 60)
    }

    @Test func 睡过了结束时间唤醒后立即进入时间到() async {
        engine.start(task)
        await settle()
        clock.advance(minutes: 90)   // timer did not run during sleep
        engine.tick()                // called by PowerMonitor after wake
        #expect(engine.phase == .timeUp)
        await settle()
        // turn off DND first, then send the reminder
        #expect(dnd.log == ["on", "off"])
        #expect(notifier.timeUps == ["阅读《第一性原理》"])
    }

    @Test func 时间到后标记完成按计划结束时间记账() async {
        engine.start(task)
        clock.advance(minutes: 60)
        engine.tick()
        clock.advance(minutes: 7)    // the user only tapped after 7 minutes
        engine.complete()
        #expect(engine.phase == .idle)
        #expect(taskStore.task(id: task.id)?.status == .done)
        let record = try? #require(sessions.finished.first)
        #expect(record?.reason == .completed)
        #expect(record?.focusedSeconds == 3600)
    }

    @Test func 时间到后延长15分钟回到计时() async {
        engine.start(task)
        clock.advance(minutes: 60)
        engine.tick()
        await settle()
        clock.advance(minutes: 2)
        engine.extend()
        await settle()
        #expect(engine.phase == .running)
        #expect(engine.remaining == 15 * 60)   // the 2 minutes of hesitation do not count
        #expect(dnd.log == ["on", "off", "on"])
    }

    @Test func 放弃后任务改回未开始() {
        engine.start(task)
        clock.advance(minutes: 10)
        engine.abandon()
        #expect(taskStore.task(id: task.id)?.status == .todo)
        #expect(sessions.finished.first?.reason == .abandoned)
        #expect(sessions.finished.first?.focusedSeconds == 600)
    }

    @Test func 已有专注时开始另一个需要确认() {
        engine.start(task)
        let other = taskStore.create(TaskSnapshot(title: "周会", start: clock.now, end: nil, isAllDay: false))
        engine.requestStart(other)
        #expect(engine.pendingSwitch == other)
        #expect(engine.session?.taskID == task.id)

        engine.confirmSwitch()
        #expect(engine.session?.taskID == other.id)
        #expect(taskStore.task(id: task.id)?.status == .todo)
        #expect(sessions.finished.count == 1)
    }

    @Test func 重启后恢复未结束的专注() {
        engine.start(task)
        clock.advance(minutes: 20)

        // simulate relaunch after the app was killed: new engine, same data
        let clock = self.clock
        let restarted = FocusEngine(taskStore: taskStore, repository: sessions, notifier: notifier,
                                    dnd: dnd, clock: { clock.now })
        restarted.restore()
        #expect(restarted.phase == .running)
        #expect(restarted.remaining == 40 * 60)
    }

    @Test func 重启时已超时直接进入时间到() {
        engine.start(task)
        clock.advance(minutes: 75)
        let clock = self.clock
        let restarted = FocusEngine(taskStore: taskStore, repository: sessions, notifier: notifier,
                                    dnd: dnd, clock: { clock.now })
        restarted.restore()
        #expect(restarted.phase == .timeUp)
    }

    @Test func 没有专注但勿扰还开着时启动会关掉勿扰() async {
        dnd.simulateLeftOn()
        engine.restore()
        await settle()
        #expect(dnd.log == ["off"])
    }

    @Test func 勿扰失败不影响计时() async {
        dnd.shouldFail = true
        engine.start(task)
        await settle()
        #expect(engine.phase == .running)
        #expect(engine.dndWarning != nil)
    }

    @Test func 专注引擎改状态不进撤销栈() {
        engine.start(task)
        taskStore.undo()
        // what gets undone is "create event", not reverting in-progress back to not-started
        #expect(tasks.items.isEmpty)
    }

    @Test func 倒计时文字格式() {
        #expect(DurationText.countdown(59.2) == "01:00")
        #expect(DurationText.countdown(3725) == "1:02:05")
        #expect(DurationText.countdown(-5) == "00:00")
        #expect(DurationText.minutes(5400) == "1小时30分")
    }
}
