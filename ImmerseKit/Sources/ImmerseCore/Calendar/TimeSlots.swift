import Foundation

/// Candidates for time pickers (pure computation, easy to test)
public enum TimeSlots {
    public static let step: TimeInterval = 15 * 60

    /// Quick durations at the top of the end-time popup (minutes)
    public static let durationPresets = [30, 60, 90, 120]

    /// Start time candidates: 00:00 to 23:45 of the day, one every 15 minutes
    public static func starts(on day: Date, calendar: Calendar) -> [Date] {
        let dayStart = calendar.startOfDay(for: day)
        return (0..<96).map { dayStart.addingTimeInterval(TimeInterval($0) * step) }
    }

    /// End time candidates: at least 15 minutes after start (aligned to the 15-minute grid), up to 24 hours after start
    public static func ends(after start: Date, calendar: Calendar) -> [Date] {
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

    /// "45分钟", "1小时", "1小时30分" (45 min, 1 hour, 1 hour 30 min)
    public static func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)分钟"
        case (_, 0): return "\(hours)小时"
        default: return "\(hours)小时\(rest)分"
        }
    }

    public static func durationText(from start: Date, to end: Date) -> String {
        durationText(minutes: max(Int(end.timeIntervalSince(start) / 60), 0))
    }
}
