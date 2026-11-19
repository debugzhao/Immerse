import Foundation
import SwiftData

/// Persisted task entity. Used only inside the data layer; always converted to `TaskSnapshot` for outside use.
@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var start: Date
    var end: Date?
    var isAllDay: Bool
    // SwiftData on macOS 14 handles enum predicates unreliably, so store the raw value and compare primitive types in queries
    var priorityRaw: Int
    var statusRaw: String
    var notes: String
    var place: String?
    var plannedMinutes: Int?
    // Added with Inbox / Goals. Optional so existing stores migrate automatically (nil kind = event)
    var kindRaw: String?
    var goalID: UUID?
    var targetMinutes: Int?
    var createdAt: Date
    var updatedAt: Date

    // Deleting a task keeps its focus sessions (the relationship is nullified), so focus stats don't lose data
    @Relationship(deleteRule: .nullify, inverse: \FocusSession.task)
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
        kindRaw = snapshot.kind.rawValue
        goalID = snapshot.goalID
        targetMinutes = snapshot.targetMinutes
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
            plannedMinutes: plannedMinutes,
            kind: kindRaw.flatMap(TaskKind.init(rawValue:)) ?? .event,
            goalID: goalID,
            targetMinutes: targetMinutes
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
        kindRaw = snapshot.kind.rawValue
        goalID = snapshot.goalID
        targetMinutes = snapshot.targetMinutes
        updatedAt = now
    }
}
