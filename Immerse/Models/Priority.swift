import Foundation

/// Task priority, following the three levels of the Notion "Main Task Schedule".
/// A smaller rawValue means higher priority; tasks in the same time slot are sorted by it.
enum Priority: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case urgent = 0
    case important = 1
    case normal = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .urgent: "紧急"
        case .important: "重要"
        case .normal: "普通"
        }
    }

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
