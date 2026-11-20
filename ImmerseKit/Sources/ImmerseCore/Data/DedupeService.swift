import Foundation
import OSLog
import SwiftData

/// Merges duplicate rows. CloudKit can't enforce unique IDs, so two devices editing offline can each upload a copy;
/// this keeps the most recently updated copy of every task / memory / setting and drops the rest.
@MainActor
public enum DedupeService {
    private static let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Dedupe")

    /// Returns the number of rows removed
    @discardableResult
    public static func run(in context: ModelContext) throws -> Int {
        var removed = 0
        removed += try dedupeTasks(in: context)
        removed += try dedupeSessions(in: context)
        removed += try dedupeMemories(in: context)
        removed += try dedupeSettings(in: context)
        if removed > 0 {
            try context.save()
            logger.info("Removed \(removed) duplicate rows")
        }
        return removed
    }

    private static func dedupeTasks(in context: ModelContext) throws -> Int {
        let groups = Dictionary(grouping: try context.fetch(FetchDescriptor<TaskItem>()), by: \.id).values
        var removed = 0
        for group in groups where group.count > 1 {
            let keep = newest(group, by: \.updatedAt)
            for duplicate in group where duplicate !== keep {
                // Re-home focus sessions first so their stats survive
                for session in duplicate.sessions ?? [] { session.task = keep }
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    private static func dedupeSessions(in context: ModelContext) throws -> Int {
        let groups = Dictionary(grouping: try context.fetch(FetchDescriptor<FocusSession>()), by: \.id).values
        var removed = 0
        for group in groups where group.count > 1 {
            // A finished copy carries more information than one that is still running; among finished ones the latest end wins
            let keep = group.max { lhs, rhs in
                (lhs.endedAt ?? .distantPast, lhs.plannedSeconds) < (rhs.endedAt ?? .distantPast, rhs.plannedSeconds)
            }
            for duplicate in group where duplicate !== keep {
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    private static func dedupeMemories(in context: ModelContext) throws -> Int {
        let groups = Dictionary(grouping: try context.fetch(FetchDescriptor<MemoryItem>()), by: \.id).values
        return deleteAllButNewest(groups, by: \.updatedAt, in: context)
    }

    private static func dedupeSettings(in context: ModelContext) throws -> Int {
        let groups = Dictionary(grouping: try context.fetch(FetchDescriptor<ProfileSetting>()), by: \.key).values
        return deleteAllButNewest(groups, by: \.updatedAt, in: context)
    }

    private static func deleteAllButNewest<Model: PersistentModel>(
        _ groups: Dictionary<some Hashable, [Model]>.Values, by date: KeyPath<Model, Date>, in context: ModelContext
    ) -> Int {
        var removed = 0
        for group in groups where group.count > 1 {
            let keep = newest(group, by: date)
            for duplicate in group where duplicate !== keep {
                context.delete(duplicate)
                removed += 1
            }
        }
        return removed
    }

    private static func newest<Model: PersistentModel>(_ group: [Model], by date: KeyPath<Model, Date>) -> Model {
        // `group` is never empty here; ties keep the first row so repeated runs are stable
        group.dropFirst().reduce(group[0]) { best, next in next[keyPath: date] > best[keyPath: date] ? next : best }
    }
}
