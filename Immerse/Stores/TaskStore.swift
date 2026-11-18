import Foundation
import Observation
import OSLog

/// 任务数据的读写入口。视图通过它取数据，写操作完成后递增 `revision` 通知视图刷新。
@MainActor
@Observable
final class TaskStore {
    @ObservationIgnored private let repository: TaskRepository
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "TaskStore")

    /// 数据版本号。读取方法内部会访问它，从而让 SwiftUI 建立依赖。
    private(set) var revision = 0

    init(repository: TaskRepository) {
        self.repository = repository
    }

    func tasks(in interval: DateInterval) -> [TaskSnapshot] {
        _ = revision
        do {
            return try repository.tasks(in: interval)
        } catch {
            logger.error("读取任务失败：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func reload() {
        revision += 1
    }
}
