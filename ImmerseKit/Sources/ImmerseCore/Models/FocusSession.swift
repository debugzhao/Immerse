import Foundation
import SwiftData

/// A single focus session. `endedAt == nil` means in progress; at most one globally (guaranteed by FocusEngine).
@Model
public final class FocusSession {
    @Attribute(.unique) public var id: UUID
    public var task: TaskItem?
    /// Redundant copy of the title so stats can still show it after the task is deleted
    public var taskTitle: String = ""
    public var startedAt: Date
    public var endedAt: Date?
    /// Planned duration, including all "+15 minutes" extensions
    public var plannedSeconds: Int
    /// Accumulated time of finished pauses
    public var pausedSeconds: Int
    /// Non-nil means currently paused
    public var pausedAt: Date?
    /// completed / finishedEarly / abandoned
    public var endReasonRaw: String?

    public init(id: UUID, task: TaskItem?, taskTitle: String, startedAt: Date, plannedSeconds: Int) {
        self.id = id
        self.task = task
        self.taskTitle = taskTitle
        self.startedAt = startedAt
        self.plannedSeconds = plannedSeconds
        pausedSeconds = 0
    }
}
