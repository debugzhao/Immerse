import Foundation
import SwiftData

@MainActor
public final class SwiftDataTaskRepository: TaskRepository {
    /// Holds the container so the database isn't released during the app's lifetime
    public let container: ModelContainer
    private let calendar: Calendar
    public var context: ModelContext { container.mainContext }

    /// How far back to look for multi-day tasks; tasks longer than 60 days are very rare, and the bound lets the predicate use an index
    private let lookback: TimeInterval = 60 * 24 * 3600

    public init(container: ModelContainer, calendar: Calendar = .app) {
        self.container = container
        self.calendar = calendar
    }

    public func tasks(in interval: DateInterval) throws -> [TaskSnapshot] {
        let upper = interval.end
        let lower = interval.start.addingTimeInterval(-lookback)
        // The predicate uses only primitive-typed fields: coarsely filter tasks whose start falls in [lower, upper); the exact interval overlap is checked in memory
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.start < upper && $0.start >= lower },
            sortBy: [SortDescriptor(\.start)]
        )
        return try context.fetch(descriptor)
            .map(\.snapshot)
            .filter { $0.kind == .event && $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
    }

    public func tasks(kind: TaskKind) throws -> [TaskSnapshot] {
        // kindRaw is optional (nil = event for rows written before this feature), so filter in memory
        let raw = kind.rawValue
        let descriptor = kind == .event
            ? FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.start)])
            : FetchDescriptor<TaskItem>(predicate: #Predicate { $0.kindRaw == raw }, sortBy: [SortDescriptor(\.start)])
        return try context.fetch(descriptor).map(\.snapshot).filter { $0.kind == kind }
    }

    public func events(linkedTo goalID: UUID) throws -> [TaskSnapshot] {
        let id: UUID? = goalID
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.goalID == id }, sortBy: [SortDescriptor(\.start)])
        return try context.fetch(descriptor).map(\.snapshot).filter { $0.kind == .event }
    }

    public func task(id: UUID) throws -> TaskSnapshot? {
        try item(id: id)?.snapshot
    }

    public func search(_ keyword: String, limit: Int) throws -> [TaskSnapshot] {
        var descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate {
                $0.title.localizedStandardContains(keyword) || $0.notes.localizedStandardContains(keyword)
            },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(\.snapshot)
    }

    public func allTasks() throws -> [TaskSnapshot] {
        try context.fetch(FetchDescriptor<TaskItem>(sortBy: [SortDescriptor(\.start)])).map(\.snapshot)
    }

    public func isEmpty() throws -> Bool {
        try context.fetchCount(FetchDescriptor<TaskItem>()) == 0
    }

    public func insert(_ snapshots: [TaskSnapshot]) throws {
        for snapshot in snapshots {
            context.insert(TaskItem(snapshot: snapshot))
        }
        try context.save()
    }

    public func upsert(_ snapshot: TaskSnapshot) throws {
        if let existing = try item(id: snapshot.id) {
            existing.apply(snapshot)
        } else {
            context.insert(TaskItem(snapshot: snapshot))
        }
        try context.save()
    }

    public func delete(id: UUID) throws {
        guard let existing = try item(id: id) else { return }
        context.delete(existing)
        try context.save()
    }

    public func item(id: UUID) throws -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
