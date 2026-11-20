import Foundation
import Testing
@testable import ImmerseCore

/// "Now" is fixed at 2026-11-18 (Wednesday) 20:00
struct FocusStatsTests {
    private let calendar = Calendar.app
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 20))! }

    private func record(day: Int, hour: Int, minutes: Int, paused: Int = 0, title: String = "阅读",
                        reason: FocusEndReason = .completed) -> FocusRecord {
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        return FocusRecord(id: UUID(), taskID: nil, taskTitle: title, startedAt: start,
                           endedAt: start.addingTimeInterval(TimeInterval((minutes + paused) * 60)),
                           focusedSeconds: minutes * 60, reason: reason)
    }

    @Test func 今日和本周汇总() {
        let stats = FocusStats(records: [
            record(day: 18, hour: 9, minutes: 60),
            record(day: 18, hour: 14, minutes: 25, paused: 10),       // paused time is not counted
            record(day: 16, hour: 9, minutes: 45, title: "周会", reason: .abandoned),
            record(day: 14, hour: 9, minutes: 30),                     // last Saturday, not this week
        ], now: now, calendar: calendar)

        #expect(stats.todayMinutes == 85)
        #expect(stats.weekMinutes == 130)
        #expect(stats.weekSessions == 3)
        #expect(stats.weekCompleted == 2)
        #expect(stats.topTasks.map(\.title) == ["阅读", "周会"])
        #expect(stats.topTasks.first?.minutes == 85)
    }

    @Test func 最近七天按日期升序且包含今天() {
        let stats = FocusStats(records: [record(day: 13, hour: 9, minutes: 50)], now: now, calendar: calendar)
        #expect(stats.lastSevenDays.count == 7)
        #expect(calendar.component(.day, from: stats.lastSevenDays.first!.date) == 12)
        #expect(calendar.component(.day, from: stats.lastSevenDays.last!.date) == 18)
        #expect(stats.lastSevenDays.first { calendar.component(.day, from: $0.date) == 13 }?.minutes == 50)
    }

    @Test func 跨午夜的专注按比例拆到两天() {
        // starts at 23:00, focuses 120 minutes until 1:00 the next day
        let stats = FocusStats(records: [record(day: 17, hour: 23, minutes: 120)], now: now, calendar: calendar)
        let byDay = Dictionary(uniqueKeysWithValues: stats.lastSevenDays.map { (calendar.component(.day, from: $0.date), $0.minutes) })
        #expect(byDay[17] == 60)
        #expect(byDay[18] == 60)
    }

    @Test func 连续专注天数() {
        let stats = FocusStats(records: [
            record(day: 18, hour: 9, minutes: 10),
            record(day: 17, hour: 9, minutes: 10),
            record(day: 16, hour: 9, minutes: 10),
            record(day: 14, hour: 9, minutes: 10),   // streak broken on the 15th
        ], now: now, calendar: calendar)
        #expect(stats.streakDays == 3)
    }

    @Test func 今天还没专注时从昨天算连续天数() {
        let stats = FocusStats(records: [record(day: 17, hour: 9, minutes: 10)], now: now, calendar: calendar)
        #expect(stats.streakDays == 1)
    }

    @Test func 没有记录时全为零() {
        let stats = FocusStats(records: [], now: now, calendar: calendar)
        #expect(stats.todayMinutes == 0)
        #expect(stats.weekCompletionRate == 0)
        #expect(stats.topTasks.isEmpty)
        #expect(stats.streakDays == 0)
    }
}
