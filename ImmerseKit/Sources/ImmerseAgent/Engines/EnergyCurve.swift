import Foundation
import ImmerseCore

/// How well the user focuses at each hour of the day, 0…1.
/// Built from finished focus sessions: minutes completed in an hour raise it, abandoned sessions pull it down.
/// With little data it leans on a generic curve (mornings best) and says so via `isPersonalized`.
public struct EnergyCurve: Equatable, Sendable {
    /// 24 values, one per hour
    public let hourly: [Double]
    /// Sessions the curve is based on
    public let sampleCount: Int

    /// Sessions needed before the curve is fully the user's own
    public static let personalThreshold = 10

    public var isPersonalized: Bool { sampleCount >= Self.personalThreshold }

    public init(hourly: [Double], sampleCount: Int) {
        precondition(hourly.count == 24)
        self.hourly = hourly
        self.sampleCount = sampleCount
    }

    /// Generic curve: morning peak, post-lunch dip, a decent afternoon, tired late evening
    public static let generic = EnergyCurve(hourly: (0..<24).map { hour in
        switch hour {
        case 9..<12: 0.9
        case 12..<14: 0.5
        case 14..<17: 0.7
        case 17..<20: 0.55
        case 20..<22: 0.45
        default: 0.3
        }
    }, sampleCount: 0)

    public static func from(records: [FocusRecord], calendar: Calendar) -> EnergyCurve {
        var minutes = Array(repeating: 0.0, count: 24)
        var samples = 0
        for record in records where record.focusedSeconds >= 5 * 60 {
            let hour = calendar.component(.hour, from: record.startedAt)
            let weight = record.reason == .abandoned ? -0.5 : 1
            minutes[hour] += weight * Double(record.focusedSeconds) / 60
            samples += 1
        }
        guard samples > 0, let peak = minutes.max(), peak > 0 else { return generic }
        // Normalize, then smooth with neighbours so one lucky session doesn't make a spike
        let normalized = minutes.map { max($0, 0) / peak }
        let smoothed = (0..<24).map { hour in
            let previous = normalized[(hour + 23) % 24], next = normalized[(hour + 1) % 24]
            return 0.25 * previous + 0.5 * normalized[hour] + 0.25 * next
        }
        let top = smoothed.max() ?? 1
        let personal = smoothed.map { top > 0 ? $0 / top : 0 }
        // Blend towards the generic curve until there are enough sessions
        let weight = min(Double(samples) / Double(personalThreshold), 1)
        let blended = (0..<24).map { weight * personal[$0] + (1 - weight) * generic.hourly[$0] }
        return EnergyCurve(hourly: blended, sampleCount: samples)
    }

    public func score(at date: Date, calendar: Calendar) -> Double {
        hourly[calendar.component(.hour, from: date)]
    }

    /// Average over the hours an interval touches
    public func score(for interval: DateInterval, calendar: Calendar) -> Double {
        var total = 0.0, count = 0
        var cursor = interval.start
        while cursor < interval.end {
            total += score(at: cursor, calendar: calendar)
            count += 1
            cursor = cursor.addingTimeInterval(3600)
        }
        return count == 0 ? score(at: interval.start, calendar: calendar) : total / Double(count)
    }

    /// Best hours first, e.g. [9, 10, 15]
    public func peakHours(count: Int = 3) -> [Int] {
        Array(hourly.enumerated().sorted { $0.element > $1.element }.prefix(count).map(\.offset)).sorted()
    }

    /// The score that marks the top 30% of the workday's hours, for "hard tasks only in high-energy time"
    public func highEnergyThreshold(workday: Workday) -> Double {
        let hours = hourly[max(workday.startHour, 0)..<min(workday.endHour, 24)].sorted(by: >)
        guard !hours.isEmpty else { return 1 }
        return hours[max(Int(Double(hours.count) * 0.3) - 1, 0)]
    }
}
