import Foundation
import Testing
@testable import ImmerseCore

struct DailyPlanTests {
    let calendar = Calendar.app

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func span(_ from: (Int, Int), _ to: (Int, Int), day: Int = 20) -> DateInterval {
        DateInterval(start: date(day, from.0, from.1), end: date(day, to.0, to.1))
    }

    @Test func 空闲时段从九点或当前时间算起到二十二点() {
        let busy = [span((8, 0), (8, 45)), span((12, 0), (12, 15)), span((12, 15), (12, 30)), span((20, 0), (21, 30))]
        // Early morning: starts at 09:00; the 08:00 event is before the window
        let morning = DailyPlan.freeSlots(busy: busy, day: date(20, 7), now: date(20, 7), calendar: calendar)
        #expect(morning == [span((9, 0), (12, 0)), span((12, 30), (20, 0)), span((21, 30), (22, 0))])

        // 12:07 now: rounded up to 12:15, still inside an event, so the first slot starts at 12:30
        let noon = DailyPlan.freeSlots(busy: busy, day: date(20, 12, 7), now: date(20, 12, 7), calendar: calendar)
        #expect(noon.first == span((12, 30), (20, 0)))
    }

    @Test func 太短的空档不算() {
        let busy = [span((9, 0), (10, 0)), span((10, 20), (21, 50))]
        let slots = DailyPlan.freeSlots(busy: busy, day: date(20, 8), now: date(20, 8), calendar: calendar)
        #expect(slots.isEmpty)   // 20 and 10 minutes are both under 30
        #expect(DailyPlan.freeSlots(busy: [], day: date(20, 22, 30), now: date(20, 22, 30), calendar: calendar).isEmpty)
    }

    @Test func 安排时长不超过空档() {
        #expect(DailyPlan.sessionMinutes(in: span((9, 0), (12, 0))) == 60)
        #expect(DailyPlan.sessionMinutes(in: span((9, 0), (9, 45))) == 45)
    }

    @Test func 每天只自动弹出一次() {
        let now = date(20, 9)
        #expect(DailyPlan.shouldPresent(lastShown: nil, now: now, hasContent: true, isEnabled: true, calendar: calendar))
        #expect(!DailyPlan.shouldPresent(lastShown: date(20, 8), now: now, hasContent: true, isEnabled: true, calendar: calendar))
        #expect(DailyPlan.shouldPresent(lastShown: date(19, 23), now: now, hasContent: true, isEnabled: true, calendar: calendar))
        #expect(!DailyPlan.shouldPresent(lastShown: nil, now: now, hasContent: false, isEnabled: true, calendar: calendar))
        #expect(!DailyPlan.shouldPresent(lastShown: nil, now: now, hasContent: true, isEnabled: false, calendar: calendar))
    }

    @Test func 想法搁置天数分级() {
        func idea(capturedOn day: Int) -> TaskSnapshot {
            TaskSnapshot(title: "想法", start: date(day, 23), end: nil, isAllDay: false, kind: .idea)
        }
        let now = date(20, 9)
        #expect(IdeaStaleness.of(idea(capturedOn: 14), now: now, calendar: calendar) == .fresh)       // 6 days
        #expect(IdeaStaleness.of(idea(capturedOn: 13), now: now, calendar: calendar) == .aging(days: 7))
        #expect(IdeaStaleness.of(idea(capturedOn: 7), now: now, calendar: calendar) == .aging(days: 13))
        #expect(IdeaStaleness.of(idea(capturedOn: 6), now: now, calendar: calendar) == .stale(days: 14))
    }

    @Test func 复盘通知附带收集箱() {
        let task = TaskSnapshot(title: "写周报", start: date(20, 10), end: date(20, 11), isAllDay: false)
        let lingering = DailyReview.InboxSummary(count: 4, oldestDays: 23)
        let content = DailyReview.content(for: [task], inbox: lingering, calendar: calendar)
        #expect(content?.body.hasSuffix("收集箱还有 4 条想法，最久的已搁置 23 天") == true)

        let fresh = DailyReview.InboxSummary(count: 2, oldestDays: 1)
        #expect(DailyReview.content(for: [task], inbox: fresh, calendar: calendar)?.body.hasSuffix("收集箱还有 2 条想法") == true)

        // No tasks: fresh ideas alone don't trigger a reminder, lingering ones do
        #expect(DailyReview.content(for: [], inbox: fresh, calendar: calendar) == nil)
        #expect(DailyReview.content(for: [], inbox: lingering, calendar: calendar)?.title == "收集箱还有 4 条想法")
        // Behind goals keep their title; the Inbox line follows
        let withGoals = DailyReview.content(for: [], behindGoals: ["读书 10%"], inbox: lingering, calendar: calendar)
        #expect(withGoals?.title == "有 1 个目标进度落后")
        #expect(withGoals?.body.hasSuffix("最久的已搁置 23 天") == true)

        #expect(DailyReview.InboxSummary(ideas: [], now: .now, calendar: calendar) == nil)
    }
}
