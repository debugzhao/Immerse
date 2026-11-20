import Foundation
import SwiftData

/// Data access for focus sessions
@MainActor
public protocol FocusSessionRepository: AnyObject {
    func activeSession() throws -> FocusSessionState?
    /// Saves the in-progress session (updates it if it exists)
    func save(_ state: FocusSessionState) throws
    func finish(_ state: FocusSessionState, endedAt: Date, reason: FocusEndReason) throws
    /// Finished sessions that overlap the interval
    func records(in interval: DateInterval) throws -> [FocusRecord]
}

@MainActor
public final class InMemoryFocusSessionRepository: FocusSessionRepository {
    public private(set) var active: FocusSessionState?
    public private(set) var finished: [FocusRecord] = []

    public init(active: FocusSessionState? = nil, finished: [FocusRecord] = []) {
        self.active = active
        self.finished = finished
    }

    public func activeSession() throws -> FocusSessionState? { active }

    public func save(_ state: FocusSessionState) throws { active = state }

    public func finish(_ state: FocusSessionState, endedAt: Date, reason: FocusEndReason) throws {
        active = nil
        finished.append(FocusRecord(
            id: state.id, taskID: state.taskID, taskTitle: state.taskTitle,
            startedAt: state.startedAt, endedAt: endedAt,
            focusedSeconds: Int(state.elapsed(at: endedAt)), reason: reason
        ))
    }

    public func records(in interval: DateInterval) throws -> [FocusRecord] {
        finished.filter { $0.startedAt < interval.end && $0.endedAt > interval.start }
    }
}

@MainActor
public final class SwiftDataFocusSessionRepository: FocusSessionRepository {
    private let tasks: SwiftDataTaskRepository
    private var context: ModelContext { tasks.context }

    public init(tasks: SwiftDataTaskRepository) {
        self.tasks = tasks
    }

    public func activeSession() throws -> FocusSessionState? {
        var descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let session = try context.fetch(descriptor).first else { return nil }
        guard let taskID = session.task?.id else {
            // The task being focused was deleted: this session can't be recovered, so end it as abandoned rather than leave it dangling forever
            session.endedAt = session.pausedAt ?? .now
            session.endReasonRaw = FocusEndReason.abandoned.rawValue
            try context.save()
            return nil
        }
        return FocusSessionState(
            id: session.id, taskID: taskID, taskTitle: session.task?.title ?? session.taskTitle,
            startedAt: session.startedAt, plannedSeconds: session.plannedSeconds,
            pausedSeconds: session.pausedSeconds, pausedAt: session.pausedAt
        )
    }

    public func save(_ state: FocusSessionState) throws {
        let session: FocusSession
        if let existing = try fetch(id: state.id) {
            session = existing
        } else {
            session = FocusSession(id: state.id, task: try tasks.item(id: state.taskID),
                                   taskTitle: state.taskTitle, startedAt: state.startedAt,
                                   plannedSeconds: state.plannedSeconds)
            context.insert(session)
        }
        session.taskTitle = state.taskTitle
        session.plannedSeconds = state.plannedSeconds
        session.pausedSeconds = state.pausedSeconds
        session.pausedAt = state.pausedAt
        try context.save()
    }

    public func finish(_ state: FocusSessionState, endedAt: Date, reason: FocusEndReason) throws {
        try save(state)
        guard let session = try fetch(id: state.id) else { return }
        // Ended while paused: count this pause toward the total paused duration
        if let pausedAt = state.pausedAt {
            session.pausedSeconds += Int(endedAt.timeIntervalSince(pausedAt))
            session.pausedAt = nil
        }
        session.endedAt = endedAt
        session.endReasonRaw = reason.rawValue
        try context.save()
    }

    public func records(in interval: DateInterval) throws -> [FocusRecord] {
        let upper = interval.end
        let lower = interval.start
        let descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate { session in
                session.startedAt < upper && session.endedAt != nil
            },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return try context.fetch(descriptor).compactMap { session in
            guard let endedAt = session.endedAt, endedAt > lower else { return nil }
            let focused = endedAt.timeIntervalSince(session.startedAt) - TimeInterval(session.pausedSeconds)
            return FocusRecord(
                id: session.id, taskID: session.task?.id,
                taskTitle: session.task?.title ?? session.taskTitle,
                startedAt: session.startedAt, endedAt: endedAt,
                focusedSeconds: max(Int(focused), 0),
                reason: FocusEndReason(rawValue: session.endReasonRaw ?? "") ?? .completed
            )
        }
    }

    private func fetch(id: UUID) throws -> FocusSession? {
        var descriptor = FetchDescriptor<FocusSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
