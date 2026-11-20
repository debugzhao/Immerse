import Foundation
import SwiftData

/// Persisted task entity. Used only inside the data layer; always converted to `TaskSnapshot` for outside use.
///
/// CloudKit rules (schema V2): no unique constraints, every attribute optional or defaulted, relationships optional.
/// Duplicates that CloudKit sync can create are merged by `DedupeService`.
@Model
public final class TaskItem {
    public var id: UUID = UUID()
    public var title: String = ""
    public var start: Date = Date.distantPast
    public var end: Date?
    public var isAllDay: Bool = false
    // SwiftData on macOS 14 / iOS 17 handles enum predicates unreliably, so store the raw value and compare primitive types in queries
    public var priorityRaw: Int = Priority.normal.rawValue
    public var statusRaw: String = TaskStatus.todo.rawValue
    public var notes: String = ""
    public var place: String?
    public var plannedMinutes: Int?
    // Added with Inbox / Goals. Optional so existing stores migrate automatically (nil kind = event)
    public var kindRaw: String?
    public var goalID: UUID?
    public var targetMinutes: Int?
    // Added with drag-to-reorder in the Inbox / Goals lists; optional so existing stores migrate automatically
    public var sortOrder: Double?
    // Added in schema V2 for the secretary features (all optional so existing stores migrate automatically)
    public var deadline: Date?
    public var categoryRaw: String?
    public var effortRaw: Int?
    public var parentID: UUID?
    public var sourceRaw: String?
    public var proposalID: UUID?
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    // Deleting a task keeps its focus sessions (the relationship is nullified), so focus stats don't lose data
    @Relationship(deleteRule: .nullify, inverse: \FocusSession.task)
    public var sessions: [FocusSession]? = []

    public init(snapshot: TaskSnapshot, now: Date = .now) {
        id = snapshot.id
        createdAt = now
        apply(snapshot, now: now)
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
            sortOrder: sortOrder,
            deadline: deadline,
            category: categoryRaw.flatMap(TaskCategory.init(rawValue:)),
            effort: effortRaw.flatMap(TaskEffort.init(rawValue:)),
            parentID: parentID,
            source: sourceRaw.flatMap(TaskSource.init(rawValue:)),
            proposalID: proposalID
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
        deadline = snapshot.deadline
        categoryRaw = snapshot.category?.rawValue
        effortRaw = snapshot.effort?.rawValue
        parentID = snapshot.parentID
        sourceRaw = snapshot.source?.rawValue
        proposalID = snapshot.proposalID
        updatedAt = now
    }
}
