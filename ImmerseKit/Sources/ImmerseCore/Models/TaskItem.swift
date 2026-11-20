import Foundation
import SwiftData

/// Persisted task entity. Used only inside the data layer; always converted to `TaskSnapshot` for outside use.
@Model
public final class TaskItem {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    // SwiftData on macOS 14 handles enum predicates unreliably, so store the raw value and compare primitive types in queries
    public var priorityRaw: Int
    public var statusRaw: String
    public var notes: String
    public var place: String?
    public var plannedMinutes: Int?
    // Added with Inbox / Goals. Optional so existing stores migrate automatically (nil kind = event)
    public var kindRaw: String?
    public var goalID: UUID?
    public var targetMinutes: Int?
    // Added with drag-to-reorder in the Inbox / Goals lists; optional so existing stores migrate automatically
    public var sortOrder: Double?
    public var createdAt: Date
    public var updatedAt: Date

    // Deleting a task keeps its focus sessions (the relationship is nullified), so focus stats don't lose data
    @Relationship(deleteRule: .nullify, inverse: \FocusSession.task)
    public var sessions: [FocusSession] = []

    public init(snapshot: TaskSnapshot, now: Date = .now) {
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
        sortOrder = snapshot.sortOrder
        createdAt = now
        updatedAt = now
    }

    public var snapshot: TaskSnapshot {
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
            targetMinutes: targetMinutes,
            sortOrder: sortOrder
        )
    }

    public func apply(_ snapshot: TaskSnapshot, now: Date = .now) {
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
        sortOrder = snapshot.sortOrder
        updatedAt = now
    }
}
