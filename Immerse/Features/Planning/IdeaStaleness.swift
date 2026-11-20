import SwiftUI

/// How long an Inbox idea has been sitting there, so forgotten ones stand out (pure, easy to test)
enum IdeaStaleness: Equatable {
    case fresh
    /// 7–13 days: worth a look
    case aging(days: Int)
    /// 14+ days: probably forgotten
    case stale(days: Int)

    static let agingDays = 7
    static let staleDays = 14

    /// Days counted between calendar days of capture and now (an idea is captured with `start` = now)
    static func days(of idea: TaskSnapshot, now: Date, calendar: Calendar) -> Int {
        let from = calendar.startOfDay(for: idea.start)
        let to = calendar.startOfDay(for: now)
        return max(calendar.dateComponents([.day], from: from, to: to).day ?? 0, 0)
    }

    static func of(_ idea: TaskSnapshot, now: Date, calendar: Calendar) -> IdeaStaleness {
        let days = days(of: idea, now: now, calendar: calendar)
        if days >= staleDays { return .stale(days: days) }
        if days >= agingDays { return .aging(days: days) }
        return .fresh
    }

    var days: Int? {
        switch self {
        case .fresh: nil
        case .aging(let days), .stale(let days): days
        }
    }

    var color: Color {
        switch self {
        case .fresh: .secondary
        case .aging: .orange
        case .stale: .red
        }
    }
}
