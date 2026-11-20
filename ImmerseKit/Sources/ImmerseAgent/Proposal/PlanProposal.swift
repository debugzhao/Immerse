import Foundation
import ImmerseCore

/// A set of calendar changes the secretary suggests. Nothing is written until the user applies it,
/// and applying writes every selected item as one undoable step.
public struct PlanProposal: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case capture, schedule, reflow, review, deadline, goal, overload, split
    }

    public enum Operation: Codable, Hashable, Sendable {
        /// A new event (or a sub-task in the Inbox)
        case create(TaskSnapshot)
        /// Move an existing task to a new time; `end == nil` keeps a start-only task start-only
        case move(id: UUID, start: Date, end: Date?)
        /// Replace an existing task with this full snapshot
        case update(TaskSnapshot)
        /// Take an event off the calendar and back to the Inbox
        case toInbox(id: UUID)

        /// The task the operation touches
        public var taskID: UUID {
            switch self {
            case .create(let task), .update(let task): task.id
            case .move(let id, _, _), .toInbox(let id): id
            }
        }
    }

    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public var id: UUID
        public var operation: Operation
        /// One sentence shown under the ghost block, e.g. 「排在 9:00，这是你精力最好的时段」
        public var reason: String
        public var isSelected: Bool

        public init(id: UUID = UUID(), operation: Operation, reason: String, isSelected: Bool = true) {
            self.id = id
            self.operation = operation
            self.reason = reason
            self.isSelected = isSelected
        }
    }

    public var id: UUID
    public var origin: Origin
    /// 「把 5 条想法排进本周的 4 个空档」
    public var summary: String
    public var items: [Item]
    /// From `ProposalValidator`: conflicts, overload after applying
    public var warnings: [String]
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: UUID = UUID(), origin: Origin, summary: String, items: [Item], warnings: [String] = [],
                createdAt: Date = .now, lifetime: TimeInterval = 24 * 3600) {
        self.id = id
        self.origin = origin
        self.summary = summary
        self.items = items
        self.warnings = warnings
        self.createdAt = createdAt
        expiresAt = createdAt.addingTimeInterval(lifetime)
    }

    public var selectedItems: [Item] { items.filter(\.isSelected) }
    public var isEmpty: Bool { items.isEmpty }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }

    /// How each selected item would look on the calendar after applying (for ghost blocks).
    /// `toInbox` items have no calendar position and are left out.
    public func previewTasks(current: (UUID) -> TaskSnapshot?) -> [(item: Item, task: TaskSnapshot)] {
        items.compactMap { item in
            switch item.operation {
            case .create(let task), .update(let task):
                return (item, task)
            case .move(let id, let start, let end):
                guard var task = current(id) else { return nil }
                task.start = start
                task.end = end
                task.isAllDay = false
                if task.kind == .idea { task.kind = .event }
                return (item, task)
            case .toInbox:
                return nil
            }
        }
    }
}
