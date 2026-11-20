import Foundation
import SwiftData

/// What a memory is about
public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    /// A constraint the scheduler must respect ("周三晚上打球")
    case rule
    /// A soft preference ("喜欢上午写东西")
    case preference
    /// Background knowledge ("在做 iOS 版")
    case fact
}

/// Who created a memory. Inferred memories only take effect after the user confirms them.
public enum MemoryOrigin: String, Codable, Sendable {
    case explicit
    case inferred
}

/// A recurring busy block — the only machine-readable constraint in v1
public struct MemoryConstraint: Codable, Hashable, Sendable {
    /// `Calendar.weekday` values: 1 = Sunday … 7 = Saturday
    public var weekdays: Set<Int>
    /// Minutes from midnight
    public var startMinute: Int
    public var endMinute: Int

    public init(weekdays: Set<Int>, startMinute: Int, endMinute: Int) {
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// The busy intervals this constraint produces inside `interval`
    public func busyIntervals(in interval: DateInterval, calendar: Calendar) -> [DateInterval] {
        guard endMinute > startMinute else { return [] }
        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            if weekdays.contains(calendar.component(.weekday, from: day)) {
                let start = max(day.addingTimeInterval(TimeInterval(startMinute * 60)), interval.start)
                let end = min(day.addingTimeInterval(TimeInterval(endMinute * 60)), interval.end)
                if end > start { result.append(DateInterval(start: start, end: end)) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

/// Value-type view of a memory (the layers above the data layer never touch `MemoryItem`)
public struct MemorySnapshot: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Shown to the user as-is, e.g. 「每周三 19:00–21:00 打球」
    public var text: String
    public var kind: MemoryKind
    public var constraint: MemoryConstraint?
    public var origin: MemoryOrigin
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, kind: MemoryKind = .rule, constraint: MemoryConstraint? = nil,
                origin: MemoryOrigin = .explicit, isActive: Bool = true, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.text = text
        self.kind = kind
        self.constraint = constraint
        self.origin = origin
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Persisted memory. Synced via CloudKit, so every attribute is defaulted and nothing is unique.
@Model
public final class MemoryItem {
    public var id: UUID = UUID()
    public var text: String = ""
    public var kindRaw: String = MemoryKind.rule.rawValue
    /// JSON-encoded `MemoryConstraint`
    public var constraintData: Data?
    public var originRaw: String = MemoryOrigin.explicit.rawValue
    public var isActive: Bool = true
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public init(snapshot: MemorySnapshot) {
        id = snapshot.id
        apply(snapshot)
    }

    public var snapshot: MemorySnapshot {
        MemorySnapshot(
            id: id, text: text, kind: MemoryKind(rawValue: kindRaw) ?? .rule,
            constraint: constraintData.flatMap { try? JSONDecoder().decode(MemoryConstraint.self, from: $0) },
            origin: MemoryOrigin(rawValue: originRaw) ?? .explicit, isActive: isActive,
            createdAt: createdAt, updatedAt: updatedAt)
    }

    public func apply(_ snapshot: MemorySnapshot) {
        text = snapshot.text
        kindRaw = snapshot.kind.rawValue
        constraintData = snapshot.constraint.flatMap { try? JSONEncoder().encode($0) }
        originRaw = snapshot.origin.rawValue
        isActive = snapshot.isActive
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt
    }
}

/// A setting the user accepted from an insight (e.g. an estimate multiplier). One logical row per `key`.
@Model
public final class ProfileSetting {
    public var key: String = ""
    /// JSON-encoded value
    public var valueData: Data?
    public var updatedAt: Date = Date.now

    public init(key: String, valueData: Data?, updatedAt: Date = .now) {
        self.key = key
        self.valueData = valueData
        self.updatedAt = updatedAt
    }
}
