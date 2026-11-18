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

struct ScrollRequest: Equatable {
    var hour: Int
    var token = UUID()
}

/// 拖拽框选出来、还没起名字的新日程
struct DraftEvent: Equatable {
    var start: Date
    var end: Date
    var isAllDay: Bool = false
}

/// 日历的浏览状态：看哪一天、什么视图、选中了哪个任务、筛选条件。
@MainActor
@Observable
final class CalendarStore {
    var anchorDate: Date
    var mode: CalendarMode = .week
    var selectedTaskID: UUID?
    let calendar: Calendar

    // 筛选与搜索
    var priorityFilter: Set<Priority> = Set(Priority.allCases)
    var statusFilter: Set<TaskStatus> = Set(TaskStatus.allCases)
    var searchText = ""

    /// 拖拽创建中的草稿
    var draft: DraftEvent?
    /// 正在拖动的任务，用来把所在列提到最上层，避免拖到相邻列时被盖住
    var draggingTaskID: UUID?
    /// 请求详情面板的标题输入框获得焦点（新建日程时）
    var wantsTitleFocus = false
    /// 请求搜索框获得焦点（⌘F）
    var wantsSearchFocus = false
    /// 命令面板是否打开
    var isCommandPalettePresented = false
    /// 时间网格滚动请求：每次赋新值都会触发一次滚动
    var scrollRequest = ScrollRequest(hour: 8)

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
        days(in: visibleInterval)
    }

    func days(in interval: DateInterval) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// 顶栏标题，例如「2026年11月」，跨月的周显示「2026年11月 – 12月」，日视图显示「2026年11月18日」。
    var title: String {
        if mode == .day {
            let c = calendar.dateComponents([.year, .month, .day], from: anchorDate)
            return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
        }
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
        if id != nil { draft = nil }
    }

    /// 跳到某个任务所在的日期并选中它
    func reveal(_ task: TaskSnapshot) {
        anchorDate = task.start
        if mode == .month { mode = .week }
        select(task.id)
        if !task.isAllDay {
            // 滚到日程开始前一小时，让它出现在可视区上部
            scrollRequest = ScrollRequest(hour: max(calendar.component(.hour, from: task.start) - 1, 0))
        }
    }

    // MARK: - 筛选

    var isFiltering: Bool {
        priorityFilter.count < Priority.allCases.count || statusFilter.count < TaskStatus.allCases.count
    }

    func passesFilter(_ task: TaskSnapshot) -> Bool {
        priorityFilter.contains(task.priority) && statusFilter.contains(task.status)
    }

    func toggle(_ priority: Priority) {
        if priorityFilter.contains(priority) { priorityFilter.remove(priority) } else { priorityFilter.insert(priority) }
    }

    func toggle(_ status: TaskStatus) {
        if statusFilter.contains(status) { statusFilter.remove(status) } else { statusFilter.insert(status) }
    }

    func resetFilters() {
        priorityFilter = Set(Priority.allCases)
        statusFilter = Set(TaskStatus.allCases)
    }

    // MARK: - 新建

    /// ⌘N 新建日程的默认时间：看今天就取下一个整点，否则取那天 9:00；时长 1 小时
    func defaultNewEventInterval(now: Date = .now) -> DateInterval {
        let base: Date
        if calendar.isDate(anchorDate, inSameDayAs: now) {
            let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            base = nextHour
        } else {
            base = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: anchorDate) ?? anchorDate
        }
        return DateInterval(start: base, duration: 3600)
    }
}
