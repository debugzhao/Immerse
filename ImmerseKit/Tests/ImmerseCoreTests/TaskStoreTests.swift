import Foundation
import Testing
@testable import ImmerseCore

@MainActor
struct TaskStoreTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() -> (TaskStore, InMemoryTaskRepository) {
        let repository = InMemoryTaskRepository()
        return (TaskStore(repository: repository), repository)
    }

    private func sample(_ title: String = "阅读") -> TaskSnapshot {
        TaskSnapshot(title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: false)
    }

    @Test func 新建后可以撤销和重做() {
        let (store, repository) = makeStore()
        let task = store.create(sample())
        #expect(repository.items.count == 1)

        store.undo()
        #expect(repository.items.isEmpty)

        store.redo()
        #expect(repository.items.first == task)
    }

    @Test func 删除后撤销能完整恢复() {
        let (store, repository) = makeStore()
        var task = store.create(sample())
        task.priority = .urgent
        task.notes = "第三章"
        store.update(task)

        store.delete(id: task.id)
        #expect(repository.items.isEmpty)
        #expect(store.toast?.showsUndo == true)

        store.undo()
        #expect(repository.items.first == task)
    }

    @Test func 修改可以逐步撤销() {
        let (store, repository) = makeStore()
        var task = store.create(sample())
        task.priority = .urgent
        store.update(task)
        task.status = .done
        store.update(task)

        store.undo()
        #expect(repository.items.first?.status == .todo)
        #expect(repository.items.first?.priority == .urgent)
        store.undo()
        #expect(repository.items.first?.priority == .normal)
    }

    @Test func 连续输入合并成一步撤销() {
        let (store, repository) = makeStore()
        var task = store.create(sample(""))
        for title in ["阅", "阅读", "阅读《", "阅读《第一性原理》"] {
            task.title = title
            store.update(task, coalescingKey: "\(task.id)-text")
        }
        #expect(repository.items.first?.title == "阅读《第一性原理》")

        store.undo()
        #expect(repository.items.first?.title == "")
        // one more undo step to undo the creation
        store.undo()
        #expect(repository.items.isEmpty)
    }

    @Test func 没有变化的更新不产生撤销步骤() {
        let (store, _) = makeStore()
        let task = store.create(sample())
        store.update(task)
        store.undo()
        #expect(!store.canUndo)
    }

    @Test func 勾选完成可以来回切换() {
        let (store, repository) = makeStore()
        let task = store.create(sample())
        store.toggleDone(task.id)
        #expect(repository.items.first?.status == .done)
        store.toggleDone(task.id)
        #expect(repository.items.first?.status == .todo)
    }

    @Test func 搜索匹配标题和备注() {
        let (store, _) = makeStore()
        var a = sample("阅读《谈判技巧》")
        a.notes = ""
        var b = sample("周会")
        b.notes = "讨论谈判策略"
        store.create(a)
        store.create(b)
        store.create(sample("健身"))

        #expect(Set(store.search("谈判").map(\.title)) == ["阅读《谈判技巧》", "周会"])
        #expect(store.search("  ").isEmpty)
    }

    @Test func 修改后版本号递增() {
        let (store, _) = makeStore()
        let before = store.revision
        store.create(sample())
        #expect(store.revision > before)
    }
}

struct EventEditingTests {
    private let calendar = Calendar.app

    private func timed(_ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int) throws -> TaskSnapshot {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h1, minute: m1)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h2, minute: m2)))
        return TaskSnapshot(title: "t", start: start, end: end, isAllDay: false)
    }

    private func hm(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let c = calendar.dateComponents([.day, .hour, .minute], from: date)
        return "\(c.day!)日\(c.hour!):\(c.minute!)"
    }

    @Test func 移动保持时长并支持跨天() throws {
        let task = try timed(9, 0, 10, 30)
        let moved = EventEditing.apply(.move, to: task, minutes: 45, days: 2, calendar: calendar)
        #expect(hm(moved.start) == "20日9:45")
        #expect(hm(moved.end) == "20日11:15")
    }

    @Test func 拉下边缘调整结束时间且不短于15分钟() throws {
        let task = try timed(9, 0, 10, 0)
        #expect(hm(EventEditing.apply(.resizeBottom, to: task, minutes: 30, days: 0, calendar: calendar).end) == "18日10:30")
        #expect(hm(EventEditing.apply(.resizeBottom, to: task, minutes: -120, days: 0, calendar: calendar).end) == "18日9:15")
    }

    @Test func 拉上边缘调整开始时间且不晚于结束前15分钟() throws {
        let task = try timed(9, 0, 10, 0)
        let earlier = EventEditing.apply(.resizeTop, to: task, minutes: -30, days: 0, calendar: calendar)
        #expect(hm(earlier.start) == "18日8:30")
        #expect(hm(earlier.end) == "18日10:0")
        #expect(hm(EventEditing.apply(.resizeTop, to: task, minutes: 120, days: 0, calendar: calendar).start) == "18日9:45")
    }

    @Test func 全天任务只能整天移动() throws {
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let task = TaskSnapshot(title: "黑客松", start: day, end: end, isAllDay: true)
        let moved = EventEditing.apply(.move, to: task, minutes: 90, days: -1, calendar: calendar)
        #expect(hm(moved.start) == "18日0:0")
        #expect(hm(moved.end) == "19日0:0")
        #expect(EventEditing.apply(.resizeBottom, to: task, minutes: 60, days: 0, calendar: calendar) == task)
    }

    @Test func 修改开始时间时保持时长() throws {
        let task = try timed(9, 0, 10, 30)
        let newStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14)))
        let moved = EventEditing.movingStart(of: task, to: newStart, calendar: calendar)
        #expect(hm(moved.end) == "18日15:30")
    }
}
