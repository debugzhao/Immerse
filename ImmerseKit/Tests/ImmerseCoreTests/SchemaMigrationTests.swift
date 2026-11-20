import Foundation
import SwiftData
import Testing
@testable import ImmerseCore

/// Frozen copies of the store layouts shipped before schema V2, used to write old-format stores on disk.
/// Entity names come from the class names, so these map onto the same "TaskItem" / "FocusSession" tables.
enum ShippedSchema019 {
    /// 0.1.8 – 0.1.9: unique IDs, Inbox / Goals fields, sort order
    @Model final class TaskItem {
        @Attribute(.unique) var id: UUID
        var title: String
        var start: Date
        var end: Date?
        var isAllDay: Bool
        var priorityRaw: Int
        var statusRaw: String
        var notes: String
        var place: String?
        var plannedMinutes: Int?
        var kindRaw: String?
        var goalID: UUID?
        var targetMinutes: Int?
        var sortOrder: Double?
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .nullify, inverse: \FocusSession.task)
        var sessions: [FocusSession] = []

        init(id: UUID, title: String, start: Date, kindRaw: String?, goalID: UUID?) {
            self.id = id
            self.title = title
            self.start = start
            end = start.addingTimeInterval(3600)
            isAllDay = false
            priorityRaw = 1
            statusRaw = "done"
            notes = "- [ ] 待办"
            plannedMinutes = 45
            self.kindRaw = kindRaw
            self.goalID = goalID
            sortOrder = 2
            createdAt = start
            updatedAt = start
        }
    }

    @Model final class FocusSession {
        @Attribute(.unique) var id: UUID
        var task: TaskItem?
        var taskTitle: String = ""
        var startedAt: Date
        var endedAt: Date?
        var plannedSeconds: Int
        var pausedSeconds: Int
        var pausedAt: Date?
        var endReasonRaw: String?

        init(id: UUID, task: TaskItem, startedAt: Date) {
            self.id = id
            self.task = task
            taskTitle = task.title
            self.startedAt = startedAt
            endedAt = startedAt.addingTimeInterval(1800)
            plannedSeconds = 2700
            pausedSeconds = 60
            endReasonRaw = "completed"
        }
    }
}

/// 0.1.0 – 0.1.4: before Inbox / Goals (no kind, goal or sort fields)
enum ShippedSchema010 {
    @Model final class TaskItem {
        @Attribute(.unique) var id: UUID
        var title: String
        var start: Date
        var end: Date?
        var isAllDay: Bool
        var priorityRaw: Int
        var statusRaw: String
        var notes: String
        var place: String?
        var plannedMinutes: Int?
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .nullify, inverse: \FocusSession.task)
        var sessions: [FocusSession] = []

        init(id: UUID, title: String, start: Date) {
            self.id = id
            self.title = title
            self.start = start
            isAllDay = true
            priorityRaw = 0
            statusRaw = "todo"
            notes = ""
            createdAt = start
            updatedAt = start
        }
    }

    @Model final class FocusSession {
        @Attribute(.unique) var id: UUID
        var task: TaskItem?
        var startedAt: Date
        var endedAt: Date?
        var plannedSeconds: Int
        var pausedSeconds: Int
        var pausedAt: Date?
        var endReasonRaw: String?

        init(id: UUID, task: TaskItem, startedAt: Date) {
            self.id = id
            self.task = task
            self.startedAt = startedAt
            plannedSeconds = 1500
            pausedSeconds = 0
        }
    }
}

@MainActor
struct SchemaMigrationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("immerse-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Immerse.store")
    }

    @Test func 从019的数据库升级后数据完整() throws {
        let url = try temporaryStoreURL()
        let taskID = UUID(), goalID = UUID(), sessionID = UUID()
        do {
            let schema = Schema([ShippedSchema019.TaskItem.self, ShippedSchema019.FocusSession.self])
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration("Immerse", schema: schema, url: url))
            let task = ShippedSchema019.TaskItem(id: taskID, title: "写方案", start: start, kindRaw: "event", goalID: goalID)
            old.mainContext.insert(task)
            old.mainContext.insert(ShippedSchema019.FocusSession(id: sessionID, task: task, startedAt: start))
            try old.mainContext.save()
        }

        let container = try PersistenceController.makeContainer(inMemory: false, url: url, cloudKitContainer: nil)
        let repository = SwiftDataTaskRepository(container: container)
        let task = try #require(try repository.task(id: taskID))
        #expect(task.title == "写方案")
        #expect(task.status == .done)
        #expect(task.priority == .important)
        #expect(task.plannedMinutes == 45)
        #expect(task.goalID == goalID)
        #expect(task.sortOrder == 2)
        #expect(task.notes == "- [ ] 待办")
        #expect(task.deadline == nil && task.category == nil && task.source == nil)

        let records = try SwiftDataFocusSessionRepository(tasks: repository)
            .records(in: DateInterval(start: start, duration: 86400))
        #expect(records.map(\.id) == [sessionID])
        #expect(records.first?.taskID == taskID)
        #expect(records.first?.focusedSeconds == 1740)

        // New V2 entities work in the upgraded store
        let memories = SwiftDataMemoryRepository(context: container.mainContext)
        try memories.upsert(MemorySnapshot(text: "周三晚上打球"))
        #expect(try memories.memories().count == 1)
    }

    @Test func 从010的数据库升级后数据完整() throws {
        let url = try temporaryStoreURL()
        let taskID = UUID(), sessionID = UUID()
        do {
            let schema = Schema([ShippedSchema010.TaskItem.self, ShippedSchema010.FocusSession.self])
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration("Immerse", schema: schema, url: url))
            let task = ShippedSchema010.TaskItem(id: taskID, title: "出差", start: start)
            old.mainContext.insert(task)
            old.mainContext.insert(ShippedSchema010.FocusSession(id: sessionID, task: task, startedAt: start))
            try old.mainContext.save()
        }

        let container = try PersistenceController.makeContainer(inMemory: false, url: url, cloudKitContainer: nil)
        let repository = SwiftDataTaskRepository(container: container)
        let task = try #require(try repository.task(id: taskID))
        #expect(task.title == "出差")
        #expect(task.isAllDay)
        #expect(task.kind == .event)
        #expect(task.priority == .urgent)
        // The session is still attached; it never finished, so it's the active one
        let active = try SwiftDataFocusSessionRepository(tasks: repository).activeSession()
        #expect(active?.id == sessionID)
        #expect(active?.taskID == taskID)
    }

    @Test func 新字段可以保存和读回() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, url: nil, cloudKitContainer: nil)
        let repository = SwiftDataTaskRepository(container: container)
        let snapshot = TaskSnapshot(title: "年终总结", start: start, isAllDay: false, deadline: start.addingTimeInterval(86400 * 3),
                                    category: .writing, effort: .hard, parentID: UUID(), source: .voice, proposalID: UUID())
        try repository.insert([snapshot])
        #expect(try repository.task(id: snapshot.id) == snapshot)
    }

    @Test func 数据模型满足CloudKit的要求() throws {
        let schema = Schema(PersistenceController.modelTypes)
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name) has a unique constraint")
            for attribute in entity.attributes {
                #expect(!attribute.isUnique, "\(entity.name).\(attribute.name) is unique")
                #expect(attribute.isOptional || attribute.defaultValue != nil,
                        "\(entity.name).\(attribute.name) needs a default value or must be optional")
            }
            for relationship in entity.relationships {
                #expect(relationship.isOptional, "\(entity.name).\(relationship.name) must be optional")
            }
        }
    }
}

/// Opt-in check against a copy of a real store: set IMMERSE_MIGRATION_STORE to the copied Immerse.store
/// (with its -wal / -shm files next to it). Never point it at the live store; opening upgrades the file in place.
@MainActor
struct RealStoreMigrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMMERSE_MIGRATION_STORE"] != nil))
    func 真实数据库副本可以升级() throws {
        let path = try #require(ProcessInfo.processInfo.environment["IMMERSE_MIGRATION_STORE"])
        let container = try PersistenceController.makeContainer(inMemory: false, url: URL(fileURLWithPath: path),
                                                                cloudKitContainer: nil)
        let tasks = try SwiftDataTaskRepository(container: container).allTasks()
        let sessions = try container.mainContext.fetchCount(FetchDescriptor<FocusSession>())
        print("Migrated copy: \(tasks.count) tasks, \(sessions) focus sessions")
        #expect(!tasks.isEmpty)
    }
}
