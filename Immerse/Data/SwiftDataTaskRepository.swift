import Foundation
import SwiftData

@MainActor
final class SwiftDataTaskRepository: TaskRepository {
    /// 持有容器，保证整个 App 生命周期内数据库不被释放
    private let container: ModelContainer
    private let calendar: Calendar
    private var context: ModelContext { container.mainContext }

    /// 跨天任务最多回溯这么久去查，超过 60 天的超长任务极少，换来谓词能走索引
    private let lookback: TimeInterval = 60 * 24 * 3600

    init(container: ModelContainer, calendar: Calendar = .app) {
        self.container = container
        self.calendar = calendar
    }

    func tasks(in interval: DateInterval) throws -> [TaskSnapshot] {
        let upper = interval.end
        let lower = interval.start.addingTimeInterval(-lookback)
        // 谓词只用基础类型字段：粗筛 start 落在 [lower, upper) 的任务，精确的区间相交放到内存里判断
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.start < upper && $0.start >= lower },
            sortBy: [SortDescriptor(\.start)]
        )
        return try context.fetch(descriptor)
            .map(\.snapshot)
            .filter { $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
    }

    func isEmpty() throws -> Bool {
        try context.fetchCount(FetchDescriptor<TaskItem>()) == 0
    }

    func insert(_ snapshots: [TaskSnapshot]) throws {
        for snapshot in snapshots {
            context.insert(TaskItem(snapshot: snapshot))
        }
        try context.save()
    }
}
