import Foundation
import SwiftData

/// 专注记录的数据访问
@MainActor
protocol FocusSessionRepository: AnyObject {
    func activeSession() throws -> FocusSessionState?
    /// 保存进行中的专注（存在则更新）
    func save(_ state: FocusSessionState) throws
    func finish(_ state: FocusSessionState, endedAt: Date, reason: FocusEndReason) throws
    /// 与 interval 有交集的已结束记录
    func records(in interval: DateInterval) throws -> [FocusRecord]
}

@MainActor
final class InMemoryFocusSessionRepository: FocusSessionRepository {
    private(set) var active: FocusSessionState?
    private(set) var finished: [FocusRecord] = []

    init(active: FocusSessionState? = nil, finished: [FocusRecord] = []) {
        self.active = active
        self.finished = finished
    }

    func activeSession() throws -> FocusSessionState? { active }

    func save(_ state: FocusSessionState) throws { active = state }

    func finish(_ state: FocusSessionState, endedAt: Date, reason: FocusEndReason) throws {
        active = nil
        finished.append(FocusRecord(
            id: state.id, taskID: state.taskID, taskTitle: state.taskTitle,
            startedAt: state.startedAt, endedAt: endedAt,
            focusedSeconds: Int(state.elapsed(at: endedAt)), reason: reason
        ))
    }

    func records(in interval: DateInterval) throws -> [FocusRecord] {
        finished.filter { $0.startedAt < interval.end && $0.endedAt > interval.start }
    }
}

@MainActor
final class SwiftDataFocusSessionRepository: FocusSessionRepository {
    private let tasks: SwiftDataTaskRepository
    private var context: ModelContext { tasks.context }

    init(tasks: SwiftDataTaskRepository) {
        self.tasks = tasks
    }

    func activeSession() throws -> FocusSessionState? {
        var descriptor = FetchDescriptor<FocusSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let session = try context.fetch(descriptor).first else { return nil }
        guard let taskID = session.task?.id else {
            // 专注中的任务被删了：这条记录没法恢复，按放弃结束掉，避免永远挂着
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

    func save(_ state: FocusSessionState) throws {
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

    func finish(_ state: FocusSessionState, endedAt: Date, reason: FocusEndReason) throws {
        try save(state)
        guard let session = try fetch(id: state.id) else { return }
        // 暂停中结束：把这段暂停也计入暂停时长
        if let pausedAt = state.pausedAt {
            session.pausedSeconds += Int(endedAt.timeIntervalSince(pausedAt))
            session.pausedAt = nil
        }
        session.endedAt = endedAt
        session.endReasonRaw = reason.rawValue
        try context.save()
    }

    func records(in interval: DateInterval) throws -> [FocusRecord] {
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
