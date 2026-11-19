import Foundation
import SwiftData

/// A single focus session. `endedAt == nil` means in progress; at most one globally (guaranteed by FocusEngine).
@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var task: TaskItem?
    /// Redundant copy of the title so stats can still show it after the task is deleted
    var taskTitle: String = ""
    var startedAt: Date
    var endedAt: Date?
    /// Planned duration, including all "+15 minutes" extensions
    var plannedSeconds: Int
    /// Accumulated time of finished pauses
    var pausedSeconds: Int
    /// Non-nil means currently paused
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
