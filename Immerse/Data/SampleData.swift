import Foundation

#if DEBUG
/// Demo data for DEBUG screenshots only (IMMERSE_SNAPSHOT). Never compiled into Release builds and never written to a real store.
/// Titles are generic examples, spread across this week, covering overlap, all-day, multi-day and every status.
enum SampleData {
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

        let month = GoalPeriod.month.range(containing: date, calendar: calendar)
        let week = GoalPeriod.week.range(containing: date, calendar: calendar)
        let reading = TaskSnapshot(title: "读完《纳瓦尔宝典》", start: month.start, end: month.lastDay, isAllDay: true,
                                   priority: .important, kind: .goal, targetMinutes: 600)
        let workout = TaskSnapshot(title: "每周健身 3 次", start: week.start, end: week.lastDay, isAllDay: true, kind: .goal)
        func session(_ goal: TaskSnapshot, _ d: Int, _ h: Int, _ status: TaskStatus = .todo) -> TaskSnapshot {
            TaskSnapshot(title: goal.title, start: at(d, h), end: at(d, h + 1), isAllDay: false,
                         priority: goal.priority, status: status, goalID: goal.id)
        }
        let planning: [TaskSnapshot] = [
            reading, workout,
            session(reading, 0, 20, .done), session(reading, 3, 20), session(workout, 1, 7, .done), session(workout, 4, 7),
            TaskSnapshot(title: "找全球工作的 Agent", start: date, end: nil, isAllDay: false, kind: .idea),
            TaskSnapshot(title: "研究个人网站方案", start: date, end: nil, isAllDay: false, kind: .idea),
            TaskSnapshot(title: "换一个记账 App", start: date, end: nil, isAllDay: false, kind: .idea),
        ]

        return planning + [
            // Monday
            allDay("整理本周目标", 0, nil, .urgent, .done),
            timed("晨间阅读", 0, 9, 30, 11, 0, .important, .done),
            timed("产品需求评审", 0, 14, 0, 15, 30, .urgent),
            timed("回复邮件", 0, 14, 30, 16, 0, .normal),
            // Tuesday
            allDay("学习新技能", 1, nil, .important),
            timed("读书 30 页", 1, 10, 0, 11, 0, .normal),
            timed("整理学习笔记", 1, 16, 0, 16, 45, .normal),
            // Wednesday: three overlapping tasks to verify the side-by-side layout
            timed("写项目方案", 2, 9, 0, 12, 0, .urgent, .inProgress),
            timed("周会", 2, 10, 0, 11, 0, .normal, place: "3F 会议室"),
            timed("Code Review", 2, 10, 30, 11, 30, .important),
            // Thursday to Friday: multi-day all-day task
            allDay("出差", 3, 4, .important),
            timed("和团队同步进度", 3, 15, 0, 16, 0, .normal),
            // Friday
            timed("复盘本周", 4, 20, 0, 21, 30, .important),
            // Weekend
            timed("健身", 5, 10, 0, 11, 0, .normal, place: "健身房"),
            timed("规划下周", 6, 21, 0, 22, 0, .urgent),
        ]
    }
}
#endif
