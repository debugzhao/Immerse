import Foundation
import SwiftUI

/// 日历视图的尺寸常量
enum CalendarMetrics {
    static let hourHeight: CGFloat = 48
    static let gutterWidth: CGFloat = 56
    static let dayHeaderHeight: CGFloat = 44
    static let allDayLaneHeight: CGFloat = 22
    static let allDayMinHeight: CGFloat = 28
    /// 打开时默认滚动到的小时
    static let initialScrollHour = 8
    /// 日程块的最小高度，以及它对应的、参与重叠判断的最短时长
    static let minimumEventHeight: CGFloat = 20
    static var minimumEventDuration: TimeInterval { TimeInterval(minimumEventHeight / hourHeight * 3600) }

    static var gridHeight: CGFloat { hourHeight * 24 }

    static func scrollAnchorID(_ hour: Int) -> String { "hour-anchor-\(hour)" }

    /// date 在当天时间网格上的 y 坐标
    static func yOffset(for date: Date, dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourHeight
    }

    /// 拖拽吸附粒度（分钟）
    static let snapMinutes = 15

    /// 网格上的 y 坐标对应的时间，吸附到 15 分钟，并限制在当天范围内
    static func date(forY y: CGFloat, dayStart: Date) -> Date {
        let minutes = Double(y / hourHeight) * 60
        let snapped = (minutes / Double(snapMinutes)).rounded() * Double(snapMinutes)
        let clamped = min(max(snapped, 0), 24 * 60)
        return dayStart.addingTimeInterval(clamped * 60)
    }

    /// 拖动的竖直位移对应的分钟数，吸附到 15 分钟
    static func snappedMinutes(forDeltaY dy: CGFloat) -> Int {
        let minutes = Double(dy / hourHeight) * 60
        return Int((minutes / Double(snapMinutes)).rounded()) * snapMinutes
    }
}

enum TimeText {
    static func hhmm(_ date: Date, calendar: Calendar = .app) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func range(_ start: Date, _ end: Date, calendar: Calendar = .app) -> String {
        "\(hhmm(start, calendar: calendar)) – \(hhmm(end, calendar: calendar))"
    }

    /// 「周一」这样的星期简称
    static func weekday(_ date: Date, calendar: Calendar = .app) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        return calendar.shortWeekdaySymbols[index]
    }
}

extension Calendar {
    func isWeekend(_ date: Date) -> Bool {
        isDateInWeekend(date)
    }

    /// 从 from 到 date 相差的天数（按 0 点对齐）
    func dayOffset(from: Date, to date: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: from), to: startOfDay(for: date)).day ?? 0
    }
}
