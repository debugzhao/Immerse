import Foundation

/// 时间选择列表的候选项（纯计算，便于测试）
enum TimeSlots {
    static let step: TimeInterval = 15 * 60

    /// 结束时间弹窗顶部的快捷时长（分钟）
    static let durationPresets = [30, 60, 90, 120]

    /// 开始时间候选：当天 00:00 到 23:45，每 15 分钟一个
    static func starts(on day: Date, calendar: Calendar) -> [Date] {
        let dayStart = calendar.startOfDay(for: day)
        return (0..<96).map { dayStart.addingTimeInterval(TimeInterval($0) * step) }
    }

    /// 结束时间候选：开始后至少 15 分钟（对齐到 15 分钟刻度），最多到开始后 24 小时
    static func ends(after start: Date, calendar: Calendar) -> [Date] {
        let dayStart = calendar.startOfDay(for: start)
        let earliest = start.addingTimeInterval(EventEditing.minimumDuration)
        let firstIndex = Int((earliest.timeIntervalSince(dayStart) / step).rounded(.up))
        let limit = start.addingTimeInterval(24 * 3600)
        var result: [Date] = []
        var index = firstIndex
        while true {
            let candidate = dayStart.addingTimeInterval(TimeInterval(index) * step)
            guard candidate <= limit else { break }
            result.append(candidate)
            index += 1
        }
        return result
    }

    /// 「45分钟」「1小时」「1小时30分」
    static func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)分钟"
        case (_, 0): return "\(hours)小时"
        default: return "\(hours)小时\(rest)分"
        }
    }

    static func durationText(from start: Date, to end: Date) -> String {
        durationText(minutes: max(Int(end.timeIntervalSince(start) / 60), 0))
    }
}
