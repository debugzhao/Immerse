import Foundation
import ImmerseCore
import SwiftData

/// Direct access to the App Group store for code that runs outside the app (widget timeline, widget buttons).
/// Inside the app, intents go through `AppModel` instead so the app's own store and undo history stay in charge.
@MainActor
enum SharedStore {
    static let appGroup = "group.com.debugzhao.immerse"

    private static var cached: ModelContainer?

    static func container() throws -> ModelContainer {
        if let cached { return cached }
        let container = try PersistenceController.makeContainer(
            storeURL: try PersistenceController.defaultStoreURL(appGroup: appGroup), cloudKitContainer: nil)
        cached = container
        return container
    }

    static func repository() throws -> SwiftDataTaskRepository {
        SwiftDataTaskRepository(container: try container())
    }

    /// Today's unfinished events, timed ones first, then by priority and time
    static func todayTasks(now: Date = .now, calendar: Calendar = .app) -> [TaskSnapshot] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let tasks = (try? repository().tasks(in: DateInterval(start: start, end: end))) ?? []
        return tasks.filter { $0.status != .done }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                if a.priority != b.priority { return a.priority < b.priority }
                return a.start < b.start
            }
    }

    static func task(id: UUID) -> TaskSnapshot? {
        try? repository().task(id: id)
    }

    static func setDone(_ id: UUID) {
        guard let repository = try? repository(), var task = try? repository.task(id: id) else { return }
        task.status = .done
        try? repository.upsert(task)
    }

    static func captureIdea(_ title: String, source: TaskSource) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let repository = try? repository() else { return }
        try? repository.insert([TaskSnapshot(title: trimmed, start: .now, isAllDay: false, kind: .idea, source: source)])
    }
}
