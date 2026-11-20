import Foundation

/// Content of the daily review reminder (pure computation, easy to test)
public enum DailyReview {
    public static let maxListed = 5

    /// What's waiting in the Inbox, so the evening review can nudge about it
    public struct InboxSummary: Equatable {
        public let count: Int
        /// Days the oldest idea has been sitting there
        public let oldestDays: Int

        public init?(ideas: [TaskSnapshot], now: Date, calendar: Calendar) {
            guard !ideas.isEmpty else { return nil }
            count = ideas.count
            oldestDays = ideas.map { IdeaStaleness.days(of: $0, now: now, calendar: calendar) }.max() ?? 0
        }

        public init(count: Int, oldestDays: Int) {
            self.count = count
            self.oldestDays = oldestDays
        }

        /// Ideas only earn a reminder of their own once something has been left for a while
        public var isLingering: Bool { oldestDays >= IdeaStaleness.agingDays }

        public var line: String {
            isLingering ? "收集箱还有 \(count) 条想法，最久的已搁置 \(oldestDays) 天" : "收集箱还有 \(count) 条想法"
        }
    }

    /// Next reminder time: today if today's reminder time hasn't passed, otherwise tomorrow
    public static func nextFireDate(after now: Date, minutes: Int, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let fire = today.addingTimeInterval(TimeInterval(minutes * 60))
        if fire > now { return fire }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        return tomorrow.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Returns nil when that day has no tasks, no goal is behind and nothing has lingered in the Inbox (no reminder).
    /// `behindGoals` are lines like "读完《纳瓦尔宝典》 30%", appended under the task list; the Inbox line comes last.
    public static func content(for tasks: [TaskSnapshot], behindGoals: [String] = [], inbox: InboxSummary? = nil,
                        calendar: Calendar) -> (title: String, body: String)? {
        let inboxLines = inbox.map { ["", $0.line] } ?? []
        let goalLines = (behindGoals.isEmpty ? [] : ["", "进度落后的目标："] + behindGoals.map { "· \($0)" }) + inboxLines
        guard !tasks.isEmpty else {
            if !behindGoals.isEmpty {
                return ("有 \(behindGoals.count) 个目标进度落后",
                        (behindGoals.map { "· \($0)" } + inboxLines).joined(separator: "\n"))
            }
            guard let inbox, inbox.isLingering else { return nil }
            return ("收集箱还有 \(inbox.count) 条想法", "最久的已搁置 \(inbox.oldestDays) 天，花几分钟把它们安排进日历吧")
        }
        let unfinished = tasks
            .filter { $0.status != .done }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
        guard !unfinished.isEmpty else {
            return ("今天的任务全部完成 🎉", (["\(tasks.count) 个任务都搞定了，早点休息"] + goalLines).joined(separator: "\n"))
        }
        var lines = unfinished.prefix(maxListed).map { task in
            let time = task.isAllDay ? "全天" : TimeText.hhmm(task.start, calendar: calendar)
            return "· \(time)  \(task.displayTitle)"
        }
        if unfinished.count > maxListed {
            lines.append("…还有 \(unfinished.count - maxListed) 个")
        }
        return ("今天还有 \(unfinished.count) 个任务没完成", (lines + goalLines).joined(separator: "\n"))
    }
}
