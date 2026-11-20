import Foundation

/// "今日规划": once a day, put the Inbox and lagging goals in front of the user next to today's free time
/// (pure computation, easy to test)
public enum DailyPlan {
    /// Free time is looked for inside this part of the day
    public static let dayStartHour = 9
    public static let dayEndHour = 22
    /// Gaps shorter than this aren't offered
    public static let minimumSlotMinutes = 30
    /// Length of a session booked from the panel (trimmed to the slot)
    public static let sessionMinutes = 60

    /// Gaps between today's timed events from max(09:00, now) to 22:00, each at least 30 minutes.
    /// "Now" is rounded up to the next quarter hour so a slot never starts in the past.
    public static func freeSlots(busy: [DateInterval], day: Date, now: Date, calendar: Calendar) -> [DateInterval] {
        let dayStart = calendar.startOfDay(for: day)
        guard let open = calendar.date(byAdding: .hour, value: dayStartHour, to: dayStart),
              let close = calendar.date(byAdding: .hour, value: dayEndHour, to: dayStart) else { return [] }
        var cursor = max(open, roundedUpToQuarter(now, calendar: calendar))
        var slots: [DateInterval] = []
        for interval in busy.sorted(by: { $0.start < $1.start }) where interval.end > cursor {
            if interval.start >= close { break }
            if interval.start > cursor { slots.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if close > cursor { slots.append(DateInterval(start: cursor, end: close)) }
        return slots.filter { $0.duration >= TimeInterval(minimumSlotMinutes * 60) }
    }

    /// Show the panel at most once a day, only when it's switched on and there's something to plan
    public static func shouldPresent(lastShown: Date?, now: Date, hasContent: Bool, isEnabled: Bool, calendar: Calendar) -> Bool {
        guard isEnabled, hasContent else { return false }
        guard let lastShown else { return true }
        return !calendar.isDate(lastShown, inSameDayAs: now)
    }

    /// Minutes to book in a slot: the default session, cut short if the slot is shorter
    public static func sessionMinutes(in slot: DateInterval) -> Int {
        min(sessionMinutes, Int(slot.duration / 60))
    }

    private static func roundedUpToQuarter(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let seconds = (components.minute ?? 0) * 60 + (components.second ?? 0)
        let hasFraction = seconds % 900 != 0 || (components.nanosecond ?? 0) != 0
        guard hasFraction else { return date }
        let floor = date.addingTimeInterval(-TimeInterval(seconds % 900) - TimeInterval(components.nanosecond ?? 0) / 1e9)
        return floor.addingTimeInterval(900)
    }
}
