import Foundation

/// 任务数据访问的抽象。上层只认识 `TaskSnapshot`，不关心底层是 SwiftData 还是别的存储。
@MainActor
protocol TaskRepository: AnyObject {
    /// 返回在日历上与 interval 有交集的任务（按半开区间判断），按开始时间升序。
    func tasks(in interval: DateInterval) throws -> [TaskSnapshot]
    func task(id: UUID) throws -> TaskSnapshot?
    /// 标题或备注包含关键字的任务，按开始时间倒序，最多 limit 条。
    func search(_ keyword: String, limit: Int) throws -> [TaskSnapshot]
    func allTasks() throws -> [TaskSnapshot]
    func isEmpty() throws -> Bool
    func insert(_ snapshots: [TaskSnapshot]) throws
    /// 存在则更新，不存在则插入
    func upsert(_ snapshot: TaskSnapshot) throws
    func delete(id: UUID) throws
}

/// 内存实现：给单元测试和 SwiftUI 预览用。
@MainActor
final class InMemoryTaskRepository: TaskRepository {
    private(set) var items: [TaskSnapshot]
    private let calendar: Calendar

    init(items: [TaskSnapshot] = [], calendar: Calendar = .app) {
        self.items = items
        self.calendar = calendar
    }

    func tasks(in interval: DateInterval) throws -> [TaskSnapshot] {
        items
            .filter { $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
            .sorted { $0.start < $1.start }
    }

    func task(id: UUID) throws -> TaskSnapshot? {
        items.first { $0.id == id }
    }

    func search(_ keyword: String, limit: Int) throws -> [TaskSnapshot] {
        Array(items
            .filter { $0.title.localizedStandardContains(keyword) || $0.notes.localizedStandardContains(keyword) }
            .sorted { $0.start > $1.start }
            .prefix(limit))
    }

    func allTasks() throws -> [TaskSnapshot] {
        items.sorted { $0.start < $1.start }
    }

    func isEmpty() throws -> Bool { items.isEmpty }

    func insert(_ snapshots: [TaskSnapshot]) throws {
        items.append(contentsOf: snapshots)
    }

    func upsert(_ snapshot: TaskSnapshot) throws {
        if let index = items.firstIndex(where: { $0.id == snapshot.id }) {
            items[index] = snapshot
        } else {
            items.append(snapshot)
        }
    }

    func delete(id: UUID) throws {
        items.removeAll { $0.id == id }
    }
}
