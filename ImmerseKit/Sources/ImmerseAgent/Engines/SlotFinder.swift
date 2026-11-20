import Foundation
import ImmerseCore

/// A free stretch of time inside the workday, with how good the user's focus usually is then
public struct FreeSlot: Equatable, Sendable {
    public var interval: DateInterval
    public var energy: Double

    public init(interval: DateInterval, energy: Double) {
        self.interval = interval
        self.energy = energy
    }

    public var minutes: Int { Int(interval.duration / 60) }
}

/// Finds free time across several days, around events, external meetings and memory rules.
/// Generalizes `DailyPlan.freeSlots` (one day, no energy) to what the secretary needs.
public enum SlotFinder {
    public static let minimumMinutes = 30

    public static func freeSlots(in range: DateInterval, context: PlanningContext,
                                 excluding excluded: Set<UUID> = [], minimumMinutes: Int = minimumMinutes,
                                 energy: EnergyCurve? = nil) -> [FreeSlot] {
        let calendar = context.calendar
        let curve = energy ?? context.energy
        let busy = context.busyIntervals(in: range, excluding: excluded)
        let earliest = roundedUpToQuarter(max(range.start, context.now), calendar: calendar)
        var slots: [FreeSlot] = []
        var day = calendar.startOfDay(for: range.start)
        while day < range.end {
            if let window = context.workday.window(on: day, calendar: calendar) {
                let open = max(window.start, earliest, range.start)
                let close = min(window.end, range.end)
                if close > open {
                    for gap in gaps(in: DateInterval(start: open, end: close), busy: busy)
                    where gap.duration >= TimeInterval(minimumMinutes * 60) {
                        slots.append(FreeSlot(interval: gap, energy: curve.score(for: gap, calendar: calendar)))
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return slots
    }

    /// The parts of `window` not covered by `busy` (which must be sorted by start)
    static func gaps(in window: DateInterval, busy: [DateInterval]) -> [DateInterval] {
        var cursor = window.start
        var result: [DateInterval] = []
        for interval in busy where interval.end > cursor {
            if interval.start >= window.end { break }
            if interval.start > cursor { result.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if window.end > cursor { result.append(DateInterval(start: cursor, end: window.end)) }
        return result
    }

    static func roundedUpToQuarter(_ date: Date, calendar: Calendar) -> Date {
        let seconds = date.timeIntervalSince(calendar.startOfDay(for: date))
        let quarter: TimeInterval = 15 * 60
        let rounded = (seconds / quarter).rounded(.up) * quarter
        return calendar.startOfDay(for: date).addingTimeInterval(rounded)
    }
}
