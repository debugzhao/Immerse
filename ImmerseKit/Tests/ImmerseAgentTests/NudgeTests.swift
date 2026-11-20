import Foundation
import ImmerseCore
import Testing
@testable import ImmerseAgent

struct NudgeTests {
    private let calendar = Fixture.calendar

    private func nudge(_ kind: Nudge.Kind, _ hour: Int, _ minute: Int = 0) -> Nudge {
        Nudge(kind: kind, fireDate: Fixture.date(18, hour, minute), title: "\(kind)", body: "", isPassive: true)
    }

    @Test func 预算内按重要程度保留() {
        let picked = NudgePlanner.select([nudge(.morning, 8, 30), nudge(.overload, 12), nudge(.deadlineRisk, 12)],
                                         budget: 3, reviewCounts: true, quiet: [], now: Fixture.date(18, 7), calendar: calendar)
        // Review takes one slot; risk beats the morning briefing; overload is dropped (morning covers it anyway)
        #expect(picked.map(\.kind) == [.morning, .deadlineRisk])
    }

    @Test func 预算为零时一条都不发() {
        #expect(NudgePlanner.select([nudge(.deadlineRisk, 12)], budget: 1, reviewCounts: true, quiet: [],
                                    now: Fixture.date(18, 7), calendar: calendar).isEmpty)
    }

    @Test func 专注期间的提醒推迟到结束后() {
        let focus = DateInterval(start: Fixture.date(18, 11, 30), end: Fixture.date(18, 13))
        let picked = NudgePlanner.select([nudge(.deadlineRisk, 12)], budget: 3, reviewCounts: false, quiet: [focus],
                                         now: Fixture.date(18, 11, 40), calendar: calendar)
        #expect(picked.first?.fireDate == Fixture.date(18, 13, 1))
    }

    @Test func 已经过去的不再安排() {
        #expect(NudgePlanner.select([nudge(.morning, 8, 30)], budget: 3, reviewCounts: false, quiet: [],
                                    now: Fixture.date(18, 9), calendar: calendar).isEmpty)
    }

    @MainActor
    @Test func 晨间简报内容() {
        let tasks = [Fixture.event("写方案", 18, 9, priority: .urgent), Fixture.event("回邮件", 18, 14), Fixture.event("健身", 18, 19),
                     Fixture.event("读书", 18, 21)]
        let meeting = ExternalEvent(id: "m", title: "周会", start: Fixture.date(18, 10), end: Fixture.date(18, 11), isAllDay: false)
        let context = Fixture.context(tasks: tasks, external: [meeting], now: Fixture.date(18, 6))
        let insights = SecretaryInsights(today: LoadEstimator.load(on: Fixture.date(18), context: context),
                                         tomorrow: LoadEstimator.load(on: Fixture.date(19), context: context),
                                         risks: [], calibration: [], behindGoals: [], energy: .generic)
        let brief = MorningBrief.make(day: Fixture.date(18), context: context, insights: insights)
        #expect(brief?.title == "早安，今天 4 件事")
        #expect(brief?.body.contains("要事：写方案、回邮件、健身") == true)
        #expect(brief?.body.contains("1 个会议，第一个 10:00") == true)
        #expect(MorningBrief.make(day: Fixture.date(18), context: Fixture.context(), insights: insights) == nil)
    }

    @Test func 晚间复盘顺延到明天() {
        let unfinished = Fixture.event("没写完", 18, 14)
        let done = Fixture.event("写完了", 18, 9, status: .done)
        let context = Fixture.context(tasks: [unfinished, done], records: [Fixture.record(done, day: 18, hour: 9, minutes: 50)],
                                      now: Fixture.date(18, 21))
        let summary = EveningReview.summary(for: Fixture.date(18), context: context)
        #expect(summary.done == 1 && summary.total == 2 && summary.focusedMinutes == 50)
        #expect(summary.unfinished.map(\.id) == [unfinished.id])
        let proposal = EveningReview.carryOver(summary.unfinished, from: Fixture.date(18), context: context)
        guard case .move(let id, let start, _)? = proposal?.items.first?.operation else { Issue.record("no move"); return }
        #expect(id == unfinished.id)
        #expect(Fixture.calendar.isDate(start, inSameDayAs: Fixture.date(19)))
    }
}
