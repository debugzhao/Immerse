import Foundation

/// Abstraction over task data access. Upper layers only know `TaskSnapshot`, regardless of whether storage is SwiftData or something else.
@MainActor
protocol TaskRepository: AnyObject {
    /// Returns tasks that overlap the interval on the calendar (half-open interval semantics), sorted by start time ascending.
    func tasks(in interval: DateInterval) throws -> [TaskSnapshot]
    func task(id: UUID) throws -> TaskSnapshot?
    /// Tasks whose title or notes contain the keyword, sorted by start time descending, at most `limit`.
    func search(_ keyword: String, limit: Int) throws -> [TaskSnapshot]
    func allTasks() throws -> [TaskSnapshot]
    func isEmpty() throws -> Bool
    func insert(_ snapshots: [TaskSnapshot]) throws
    /// Updates if it exists, inserts otherwise
    func upsert(_ snapshot: TaskSnapshot) throws
    func delete(id: UUID) throws
}

/// In-memory implementation for unit tests and SwiftUI previews.
@MainActor
final class InMemoryTaskRepository: TaskRepository {
    private(set) var items: [TaskSnapshot]
    private let calendar: Calendar

    init(items: [TaskSnapshot] = [], calendar: Calendar = .app) {
        self.items = items
        self.calendar = calendar
    }

    func tasks(in interval: DateInterval) throws -> [TaskSnapshot] {
        items
            .filter { $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
            .sorted { $0.start < $1.start }
    }

    func task(id: UUID) throws -> TaskSnapshot? {
        items.first { $0.id == id }
    }

    func search(_ keyword: String, limit: Int) throws -> [TaskSnapshot] {
        Array(items
            .filter { $0.title.localizedStandardContains(keyword) || $0.notes.localizedStandardContains(keyword) }
            .sorted { $0.start > $1.start }
            .prefix(limit))
    }

    func allTasks() throws -> [TaskSnapshot] {
        items.sorted { $0.start < $1.start }
    }

    func isEmpty() throws -> Bool { items.isEmpty }

    func insert(_ snapshots: [TaskSnapshot]) throws {
        items.append(contentsOf: snapshots)
    }

    func upsert(_ snapshot: TaskSnapshot) throws {
        if let index = items.firstIndex(where: { $0.id == snapshot.id }) {
            items[index] = snapshot
        } else {
            items.append(snapshot)
        }
    }

    func delete(id: UUID) throws {
        items.removeAll { $0.id == id }
    }
}
