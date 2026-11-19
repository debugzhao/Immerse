import Foundation
import OSLog

/// Dev-time mock data: tasks taken from the Notion "Main Task Schedule", spread across this week, covering overlap, all-day, multi-day and every status.
enum SampleData {
    private static let seededKey = "didSeedSampleData"
    private static let logger = Logger(subsystem: "com.debugzhao.immerse", category: "SampleData")

    /// Only written when the database is empty and has never been seeded; it won't reappear after the user deletes everything.
    @MainActor
    static func seedIfNeeded(_ repository: TaskRepository, now: Date = .now, calendar: Calendar = .app) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededKey) else { return }
        do {
            if try repository.isEmpty() {
                try repository.insert(make(around: now, calendar: calendar))
            }
            defaults.set(true, forKey: seededKey)
        } catch {
            logger.error("写入示例数据失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// For screenshot demos: adds a few focus sessions for this week's completed / in-progress timed tasks
    @MainActor
    static func seedFocusHistory(_ focus: FocusSessionRepository, tasks: TaskRepository,
                                 now: Date = .now, calendar: Calendar = .app) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let all = try? tasks.tasks(in: week) else { return }
        for task in all where !task.isAllDay && task.start < now && task.status != .inProgress {
            let interval = task.displayInterval(in: calendar)
            // Actual focus starts 5 minutes later than planned and runs 10 minutes shorter, to demo the "actual vs planned" difference
            let start = interval.start.addingTimeInterval(5 * 60)
            let seconds = max(Int(interval.duration) - 15 * 60, 15 * 60)
            let state = FocusSessionState(taskID: task.id, taskTitle: task.title, startedAt: start, plannedSeconds: seconds)
            try? focus.save(state)
            try? focus.finish(state, endedAt: start.addingTimeInterval(TimeInterval(seconds)),
                              reason: task.status == .done ? .completed : .finishedEarly)
        }
    }

    static func make(around date: Date, calendar: Calendar = .app) -> [TaskSnapshot] {
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)

        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let d = calendar.date(byAdding: .day, value: day, to: weekStart) ?? weekStart
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
        }
        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        }
        func timed(_ title: String, _ d: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int,
                   _ priority: Priority, _ status: TaskStatus = .todo, place: String? = nil) -> TaskSnapshot {
            TaskSnapshot(title: title, start: at(d, h1, m1), end: at(d, h2, m2), isAllDay: false,
                         priority: priority, status: status, place: place)
        }
        func allDay(_ title: String, _ from: Int, _ to: Int? = nil,
                    _ priority: Priority, _ status: TaskStatus = .todo) -> TaskSnapshot {
            TaskSnapshot(title: title, start: day(from), end: to.map(day), isAllDay: true,
                         priority: priority, status: status)
        }

        return [
            // Monday
            allDay("了解 Creative 链，完成第一天的任务", 0, nil, .urgent, .done),
            timed("阅读《第一性原理》", 0, 9, 30, 11, 0, .important, .done),
            timed("了解 Uniswap 协议", 0, 14, 0, 15, 30, .urgent),
            timed("学会使用区块浏览器", 0, 14, 30, 16, 0, .normal),
            // Tuesday
            allDay("了解链上数据", 1, nil, .important),
            timed("阅读《谈判技巧》", 1, 10, 0, 11, 0, .normal),
            timed("整理 DeFi 学习笔记", 1, 16, 0, 16, 45, .normal),
            // Wednesday: three overlapping tasks to verify the side-by-side layout
            timed("了解交易所概念", 2, 9, 0, 12, 0, .urgent, .inProgress),
            timed("周会", 2, 10, 0, 11, 0, .normal, place: "3F 会议室"),
            timed("Code Review", 2, 10, 30, 11, 30, .important),
            // Thursday to Friday: multi-day all-day task
            allDay("Creative 链黑客松", 3, 4, .important),
            timed("了解 Creative 链生态", 3, 15, 0, 16, 0, .normal),
            // Friday
            timed("复盘本周", 4, 20, 0, 21, 30, .important),
            // Weekend
            timed("健身", 5, 10, 0, 11, 0, .normal, place: "健身房"),
            timed("规划下周主线任务", 6, 21, 0, 22, 0, .urgent),
        ]
    }
}
