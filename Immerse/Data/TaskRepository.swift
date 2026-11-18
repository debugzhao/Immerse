import Foundation

/// 任务数据访问的抽象。上层只认识 `TaskSnapshot`，不关心底层是 SwiftData 还是别的存储。
@MainActor
protocol TaskRepository: AnyObject {
    /// 返回在日历上与 interval 有交集的任务（按半开区间判断）。
    func tasks(in interval: DateInterval) throws -> [TaskSnapshot]
    func isEmpty() throws -> Bool
    func insert(_ snapshots: [TaskSnapshot]) throws
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

    func isEmpty() throws -> Bool { items.isEmpty }

    func insert(_ snapshots: [TaskSnapshot]) throws {
        items.append(contentsOf: snapshots)
    }
}
