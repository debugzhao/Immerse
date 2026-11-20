import Foundation

extension Calendar {
    /// The calendar used app-wide: Gregorian, Chinese locale, weeks start on Monday.
    public static let app: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()
}
