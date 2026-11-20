import Foundation
import SwiftUI

/// Size constants for calendar views
enum CalendarMetrics {
    static let hourHeight: CGFloat = 48
    static let gutterWidth: CGFloat = 56
    static let dayHeaderHeight: CGFloat = 44
    static let allDayLaneHeight: CGFloat = 22
    static let allDayMinHeight: CGFloat = 28
    /// Hour to scroll to by default on open
    static let initialScrollHour = 8
    /// Minimum height of an event block (15 minutes), and the shortest duration it maps to for overlap checks.
    /// Kept at exactly one snap step so every 15-minute event is drawn the same height and back-to-back ones stack
    static let minimumEventHeight: CGFloat = 12
    static var minimumEventDuration: TimeInterval { TimeInterval(minimumEventHeight / hourHeight * 3600) }

    static var gridHeight: CGFloat { hourHeight * 24 }

    static func scrollAnchorID(_ hour: Int) -> String { "hour-anchor-\(hour)" }

    /// y coordinate of a date on that day's time grid
    static func yOffset(for date: Date, dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourHeight
    }

    /// Drag snap granularity (minutes)
    static let snapMinutes = 15

    /// Time for a y coordinate on the grid, snapped to 15 minutes and clamped to the day
    static func date(forY y: CGFloat, dayStart: Date) -> Date {
        let minutes = Double(y / hourHeight) * 60
        let snapped = (minutes / Double(snapMinutes)).rounded() * Double(snapMinutes)
        let clamped = min(max(snapped, 0), 24 * 60)
        return dayStart.addingTimeInterval(clamped * 60)
    }

    /// Minutes for a vertical drag offset, snapped to 15 minutes
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

    /// Short weekday name like "周一"
    static func weekday(_ date: Date, calendar: Calendar = .app) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        return calendar.shortWeekdaySymbols[index]
    }
}

extension Calendar {
    func isWeekend(_ date: Date) -> Bool {
        isDateInWeekend(date)
    }

    /// Number of days from `from` to `date` (aligned to midnight)
    func dayOffset(from: Date, to date: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: from), to: startOfDay(for: date)).day ?? 0
    }
}
