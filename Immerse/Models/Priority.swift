import Foundation

/// 任务优先级，沿用 Notion「主线任务日程」的三档。
/// rawValue 越小越优先，同一时段内按它排序。
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
