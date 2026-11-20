import Foundation

/// Task priority, following the three levels of the Notion "Main Task Schedule".
/// A smaller rawValue means higher priority; tasks in the same time slot are sorted by it.
public enum Priority: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case urgent = 0
    case important = 1
    case normal = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .urgent: "紧急"
        case .important: "重要"
        case .normal: "普通"
        }
    }

    public static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
