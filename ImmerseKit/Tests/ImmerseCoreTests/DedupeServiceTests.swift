import Foundation
import SwiftData
import Testing
@testable import ImmerseCore

@MainActor
struct DedupeServiceTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init() throws {
        container = try PersistenceController.makeContainer(inMemory: true, url: nil, cloudKitContainer: nil)
    }

    @Test func 保留最近修改的任务并把专注记录挂过去() throws {
        let id = UUID()
        let older = TaskItem(snapshot: TaskSnapshot(id: id, title: "旧标题", start: start, isAllDay: false), now: start)
        let newer = TaskItem(snapshot: TaskSnapshot(id: id, title: "新标题", start: start, isAllDay: false),
                             now: start.addingTimeInterval(60))
        context.insert(older)
        context.insert(newer)
        let session = FocusSession(id: UUID(), task: older, taskTitle: "旧标题", startedAt: start, plannedSeconds: 600)
        context.insert(session)
        try context.save()

        #expect(try DedupeService.run(in: context) == 1)

        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.map(\.title) == ["新标题"])
        #expect(session.task?.title == "新标题")
        // A second pass has nothing left to do
        #expect(try DedupeService.run(in: context) == 0)
    }

    @Test func 专注记录保留已经结束的那份() throws {
        let id = UUID()
        let running = FocusSession(id: id, task: nil, taskTitle: "阅读", startedAt: start, plannedSeconds: 1800)
        let finished = FocusSession(id: id, task: nil, taskTitle: "阅读", startedAt: start, plannedSeconds: 1800)
        finished.endedAt = start.addingTimeInterval(1800)
        context.insert(running)
        context.insert(finished)
        try context.save()

        #expect(try DedupeService.run(in: context) == 1)
        let left = try context.fetch(FetchDescriptor<FocusSession>())
        #expect(left.count == 1)
        #expect(left.first?.endedAt != nil)
    }

    @Test func 记忆和设置也会去重() throws {
        let memory = MemorySnapshot(text: "周三晚上打球", createdAt: start, updatedAt: start)
        context.insert(MemoryItem(snapshot: memory))
        var edited = memory
        edited.text = "周三 19:00–21:00 打球"
        edited.updatedAt = start.addingTimeInterval(10)
        context.insert(MemoryItem(snapshot: edited))
        context.insert(ProfileSetting(key: "estimate.reading", valueData: Data("1.2".utf8), updatedAt: start))
        context.insert(ProfileSetting(key: "estimate.reading", valueData: Data("1.6".utf8), updatedAt: start.addingTimeInterval(5)))
        try context.save()

        #expect(try DedupeService.run(in: context) == 2)
        let repository = SwiftDataMemoryRepository(context: context)
        #expect(try repository.memories().map(\.text) == ["周三 19:00–21:00 打球"])
        #expect(try repository.setting("estimate.reading", as: Double.self) == 1.6)
    }

    @Test func 没有重复时什么都不做() throws {
        context.insert(TaskItem(snapshot: TaskSnapshot(title: "A", start: start, isAllDay: false)))
        context.insert(TaskItem(snapshot: TaskSnapshot(title: "B", start: start, isAllDay: false)))
        try context.save()
        #expect(try DedupeService.run(in: context) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == 2)
    }
}
