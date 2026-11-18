import Foundation
import Observation

enum CalendarMode: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        }
    }
}

extension Calendar {
    /// 全 App 统一使用的日历：公历、中文、周一为每周第一天。
    static let app: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()
}

/// 日历的浏览状态：看哪一天、什么视图、选中了哪个任务。
@MainActor
@Observable
final class CalendarStore {
    var anchorDate: Date
    var mode: CalendarMode = .week
    var selectedTaskID: UUID?
    let calendar: Calendar

    init(anchorDate: Date = .now, calendar: Calendar = .app) {
        self.anchorDate = anchorDate
        self.calendar = calendar
    }

    var visibleInterval: DateInterval {
        let component: Calendar.Component = switch mode {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        return calendar.dateInterval(of: component, for: anchorDate)
            ?? DateInterval(start: calendar.startOfDay(for: anchorDate), duration: 24 * 3600)
    }

    /// 时间网格要显示的日期（每个元素是当天 0 点）。
    var visibleDays: [Date] {
        let interval = visibleInterval
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// 顶栏标题，例如「2026年11月」，跨月的周显示「2026年11月 – 12月」。
    var title: String {
        let interval = visibleInterval
        let last = interval.end.addingTimeInterval(-1)
        let (y1, m1) = (calendar.component(.year, from: interval.start), calendar.component(.month, from: interval.start))
        let (y2, m2) = (calendar.component(.year, from: last), calendar.component(.month, from: last))
        if y1 == y2 && m1 == m2 { return "\(y1)年\(m1)月" }
        if y1 == y2 { return "\(y1)年\(m1)月 – \(m2)月" }
        return "\(y1)年\(m1)月 – \(y2)年\(m2)月"
    }

    /// ISO 周数，用于标题旁的小标签
    var weekNumber: Int {
        calendar.component(.weekOfYear, from: anchorDate)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func goToToday() {
        anchorDate = .now
    }

    /// direction：-1 上一页，+1 下一页
    func step(_ direction: Int) {
        let (component, value): (Calendar.Component, Int) = switch mode {
        case .day: (.day, direction)
        case .week: (.day, 7 * direction)
        case .month: (.month, direction)
        }
        anchorDate = calendar.date(byAdding: component, value: value, to: anchorDate) ?? anchorDate
    }

    func select(_ id: UUID?) {
        selectedTaskID = id
    }
}
