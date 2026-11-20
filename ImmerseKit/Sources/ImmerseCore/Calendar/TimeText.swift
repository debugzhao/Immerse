import Foundation

/// Time formatting shared by both platforms
public enum TimeText {
    public static func hhmm(_ date: Date, calendar: Calendar = .app) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func range(_ start: Date, _ end: Date, calendar: Calendar = .app) -> String {
        "\(hhmm(start, calendar: calendar)) – \(hhmm(end, calendar: calendar))"
    }

    /// Short weekday name like "周一"
    public static func weekday(_ date: Date, calendar: Calendar = .app) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        return calendar.shortWeekdaySymbols[index]
    }
}

extension Calendar {
    public func isWeekend(_ date: Date) -> Bool {
        isDateInWeekend(date)
    }

    /// Number of days from `from` to `date` (aligned to midnight)
    public func dayOffset(from: Date, to date: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: from), to: startOfDay(for: date)).day ?? 0
    }
}
