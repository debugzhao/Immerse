import Foundation
import Testing
@testable import Immerse

struct EventLayoutEngineTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Builds a layout item from its hour offset relative to base
    private func item(_ start: Double, _ end: Double, _ priority: Priority = .normal) -> LayoutItem {
        LayoutItem(id: UUID(),
                   start: base.addingTimeInterval(start * 3600),
                   end: base.addingTimeInterval(end * 3600),
                   priority: priority)
    }

    @Test func 不重叠的日程各自独占整列() {
        let a = item(9, 10), b = item(10, 11)
        let result = EventLayoutEngine.layout([a, b])
        #expect(result[a.id] == LayoutPlacement(column: 0, columnCount: 1, span: 1))
        #expect(result[b.id] == LayoutPlacement(column: 0, columnCount: 1, span: 1))
    }

    @Test func 两个重叠的日程并排两列() {
        let a = item(9, 11), b = item(10, 12)
        let result = EventLayoutEngine.layout([a, b])
        #expect(result[a.id] == LayoutPlacement(column: 0, columnCount: 2, span: 1))
        #expect(result[b.id] == LayoutPlacement(column: 1, columnCount: 2, span: 1))
    }

    @Test func 间接重叠的日程属于同一簇并复用空出的列() {
        // A and C do not overlap directly but both overlap B, so all three share a cluster; C reuses column 0 freed by A
        let a = item(9, 10), b = item(9.5, 10.5), c = item(10, 11)
        let result = EventLayoutEngine.layout([a, b, c])
        #expect(result[a.id]?.column == 0)
        #expect(result[b.id]?.column == 1)
        #expect(result[c.id]?.column == 0)
        #expect(result.values.allSatisfy { $0.columnCount == 2 })
    }

    @Test func 右侧空闲时向右扩展() {
        // A spans three hours, B and C sit side by side in the first hour; by the time D starts both have ended, so D takes column 1 and expands right into column 2
        let a = item(9, 12), b = item(9, 10), c = item(9, 10), d = item(10.5, 11)
        let result = EventLayoutEngine.layout([a, b, c, d])
        #expect(result[a.id] == LayoutPlacement(column: 0, columnCount: 3, span: 1))
        #expect(result[d.id] == LayoutPlacement(column: 1, columnCount: 3, span: 2))
    }

    @Test func 同时开始时优先级高的排在左边() {
        let normal = item(9, 10, .normal), urgent = item(9, 10, .urgent)
        let result = EventLayoutEngine.layout([normal, urgent])
        #expect(result[urgent.id]?.column == 0)
        #expect(result[normal.id]?.column == 1)
    }

    @Test func 太短的日程按最小时长参与重叠判断() {
        // A is only 5 minutes but visually occupies at least 25, so it collides with B starting at 9:15
        let a = item(9, 9 + 5.0 / 60), b = item(9.25, 10)
        #expect(EventLayoutEngine.layout([a, b])[b.id]?.columnCount == 1)
        #expect(EventLayoutEngine.layout([a, b], minimumDuration: 25 * 60)[b.id]?.columnCount == 2)
    }

    @Test func 全天行按天分道() {
        let a = UUID(), b = UUID(), c = UUID()
        let lanes = EventLayoutEngine.allDayLanes([
            (a, 0, 2),   // Monday to Wednesday
            (b, 1, 1),   // Tuesday, conflicts with a
            (c, 3, 4),   // Thursday to Friday, can reuse a's lane
        ])
        #expect(lanes[a] == 0)
        #expect(lanes[b] == 1)
        #expect(lanes[c] == 0)
    }
}

struct TaskSnapshotTests {
    private let calendar = Calendar.app

    @Test func 全天任务覆盖首日零点到末日次日零点() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 15)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        let task = TaskSnapshot(title: "黑客松", start: start, end: end, isAllDay: true)
        let interval = task.displayInterval(in: calendar)
        #expect(interval.start == calendar.startOfDay(for: start))
        #expect(interval.duration == 2 * 24 * 3600)
    }

    @Test func 专注时长优先取显式设置其次取日期区间() {
        let start = Date(timeIntervalSince1970: 0)
        var task = TaskSnapshot(title: "阅读", start: start, end: start.addingTimeInterval(90 * 60), isAllDay: false)
        #expect(task.focusMinutes == 90)
        task.plannedMinutes = 45
        #expect(task.focusMinutes == 45)
        task = TaskSnapshot(title: "全天", start: start, end: nil, isAllDay: true)
        #expect(task.focusMinutes == TaskSnapshot.defaultFocusMinutes)
    }

    @Test func 首尾相接的区间不算重叠() {
        let a = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600)
        let b = DateInterval(start: Date(timeIntervalSince1970: 3600), duration: 3600)
        #expect(!a.overlapsHalfOpen(b))
        #expect(a.overlapsHalfOpen(DateInterval(start: Date(timeIntervalSince1970: 1800), duration: 3600)))
    }
}
