import Foundation
import SwiftData

/// 持久化的任务实体。只在数据层内部使用，对外一律转换成 `TaskSnapshot`。
@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var start: Date
    var end: Date?
    var isAllDay: Bool
    // macOS 14 的 SwiftData 对枚举谓词支持不稳定，存原始值，查询时用基础类型比较
    var priorityRaw: Int
    var statusRaw: String
    var notes: String
    var place: String?
    var plannedMinutes: Int?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \FocusSession.task)
    var sessions: [FocusSession] = []

    init(snapshot: TaskSnapshot, now: Date = .now) {
        id = snapshot.id
        title = snapshot.title
        start = snapshot.start
        end = snapshot.end
        isAllDay = snapshot.isAllDay
        priorityRaw = snapshot.priority.rawValue
        statusRaw = snapshot.status.rawValue
        notes = snapshot.notes
        place = snapshot.place
        plannedMinutes = snapshot.plannedMinutes
        createdAt = now
        updatedAt = now
    }

    var snapshot: TaskSnapshot {
        TaskSnapshot(
            id: id,
            title: title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            priority: Priority(rawValue: priorityRaw) ?? .normal,
            status: TaskStatus(rawValue: statusRaw) ?? .todo,
            notes: notes,
            place: place,
            plannedMinutes: plannedMinutes
        )
    }

    func apply(_ snapshot: TaskSnapshot, now: Date = .now) {
        title = snapshot.title
        start = snapshot.start
        end = snapshot.end
        isAllDay = snapshot.isAllDay
        priorityRaw = snapshot.priority.rawValue
        statusRaw = snapshot.status.rawValue
        notes = snapshot.notes
        place = snapshot.place
        plannedMinutes = snapshot.plannedMinutes
        updatedAt = now
    }
}
