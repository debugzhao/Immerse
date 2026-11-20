import Foundation
import Testing
@testable import ImmerseCore

@MainActor
struct MemoryTests {
    private let calendar = Calendar.app

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func 每周约束展开成忙碌时段() {
        // 2026-11-18 is a Wednesday (weekday 4)
        let wednesdayEvening = MemoryConstraint(weekdays: [4], startMinute: 19 * 60, endMinute: 21 * 60)
        let week = DateInterval(start: date(16), end: date(23))
        #expect(wednesdayEvening.busyIntervals(in: week, calendar: calendar)
                == [DateInterval(start: date(18, 19), end: date(18, 21))])
    }

    @Test func 忙碌时段裁剪到查询区间() {
        let everyDay = MemoryConstraint(weekdays: Set(1...7), startMinute: 12 * 60, endMinute: 13 * 60)
        let window = DateInterval(start: date(18, 12, 30), end: date(19, 12, 15))
        #expect(everyDay.busyIntervals(in: window, calendar: calendar) == [
            DateInterval(start: date(18, 12, 30), end: date(18, 13)),
            DateInterval(start: date(19, 12), end: date(19, 12, 15)),
        ])
    }

    @Test func 结束早于开始的约束不产生时段() {
        let broken = MemoryConstraint(weekdays: [4], startMinute: 600, endMinute: 540)
        #expect(broken.busyIntervals(in: DateInterval(start: date(16), end: date(23)), calendar: calendar).isEmpty)
    }

    @Test func SwiftData仓库读写记忆和设置() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, url: nil, cloudKitContainer: nil)
        let repository = SwiftDataMemoryRepository(context: container.mainContext)
        let constraint = MemoryConstraint(weekdays: [4], startMinute: 1140, endMinute: 1260)
        var memory = MemorySnapshot(text: "周三晚上打球", constraint: constraint, createdAt: date(1), updatedAt: date(1))
        try repository.upsert(memory)
        try repository.upsert(MemorySnapshot(text: "喜欢上午写东西", kind: .preference, createdAt: date(2), updatedAt: date(2)))
        #expect(try repository.memories().map(\.text) == ["喜欢上午写东西", "周三晚上打球"])
        #expect(try repository.activeConstraints() == [constraint])

        memory.isActive = false
        try repository.upsert(memory)
        #expect(try repository.activeConstraints().isEmpty)

        try repository.deleteMemory(id: memory.id)
        #expect(try repository.memories().count == 1)

        try repository.setSetting(1.6, for: "estimate.reading")
        #expect(try repository.setting("estimate.reading", as: Double.self) == 1.6)
        try repository.setSetting(Optional<Double>.none, for: "estimate.reading")
        #expect(try repository.setting("estimate.reading", as: Double.self) == nil)
    }
}
