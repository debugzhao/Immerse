import Foundation
import SwiftData

/// 一次专注记录。`endedAt == nil` 表示正在进行，全局最多一条（由 FocusEngine 保证）。
@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var task: TaskItem?
    /// 冗余存一份标题：任务被删后统计里仍能显示
    var taskTitle: String = ""
    var startedAt: Date
    var endedAt: Date?
    /// 计划时长，包含所有「+15 分钟」的延长
    var plannedSeconds: Int
    /// 已结束的暂停时间累计
    var pausedSeconds: Int
    /// 非 nil 表示当前处于暂停中
    var pausedAt: Date?
    /// completed / finishedEarly / abandoned
    var endReasonRaw: String?

    init(id: UUID, task: TaskItem?, taskTitle: String, startedAt: Date, plannedSeconds: Int) {
        self.id = id
        self.task = task
        self.taskTitle = taskTitle
        self.startedAt = startedAt
        self.plannedSeconds = plannedSeconds
        pausedSeconds = 0
    }
}
