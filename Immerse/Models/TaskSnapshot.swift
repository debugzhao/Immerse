import Foundation

/// 任务的值类型快照。
///
/// 数据层之上（Store、视图）只接触这个类型，不直接持有 SwiftData 的 `@Model` 对象：
/// 一来视图层不会因为托管对象的生命周期出问题，二来以后换存储（iCloud / Notion 同步）时上层不用改。
struct TaskSnapshot: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var start: Date
    /// 全天任务：最后一天（含）；定时任务：结束时间。nil 表示只有开始时间。
    var end: Date?
    var isAllDay: Bool
    var priority: Priority = .normal
    var status: TaskStatus = .todo
    var notes: String = ""
    var place: String?
    /// 计划专注时长（分钟），nil 时由日期区间推导。
    var plannedMinutes: Int?

    /// 全天任务、或只有开始时间的任务，专注时长的兜底值。
    static let defaultFocusMinutes = 60
    /// 只有开始时间的定时任务，在日历上至少画这么长。
    static let defaultDisplayMinutes = 30

    /// 在日历上占据的半开区间 [start, end)。全天任务覆盖从首日 0 点到末日次日 0 点。
    func displayInterval(in calendar: Calendar) -> DateInterval {
        if isAllDay {
            let first = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: max(end ?? start, start))
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            return DateInterval(start: first, end: endExclusive)
        }
        let fallback = start.addingTimeInterval(TimeInterval((plannedMinutes ?? Self.defaultDisplayMinutes) * 60))
        return DateInterval(start: start, end: max(end ?? fallback, start))
    }

    /// 点击「开始专注」时使用的时长：显式设置 > 日期区间 > 默认 60 分钟。
    var focusMinutes: Int {
        if let plannedMinutes, plannedMinutes > 0 { return plannedMinutes }
        if !isAllDay, let end, end > start {
            return Int(end.timeIntervalSince(start) / 60)
        }
        return Self.defaultFocusMinutes
    }
}

extension DateInterval {
    /// 按半开区间判断是否相交：首尾相接不算重叠；零时长区间落在 other 内也算。
    func overlapsHalfOpen(_ other: DateInterval) -> Bool {
        if duration == 0 {
            return start >= other.start && start < other.end
        }
        return start < other.end && end > other.start
    }
}
