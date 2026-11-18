import Foundation
import OSLog

/// 开发阶段的假数据：取自 Notion「主线任务日程」里的任务，铺满本周，覆盖重叠、全天、跨天、各种状态。
enum SampleData {
    private static let seededKey = "didSeedSampleData"
    private static let logger = Logger(subsystem: "com.debugzhao.immerse", category: "SampleData")

    /// 数据库为空且从没灌过假数据时才写入；用户删光数据后不会再冒出来。
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

    /// 截图演示用：给本周已完成 / 进行中的定时任务补几条专注记录
    @MainActor
    static func seedFocusHistory(_ focus: FocusSessionRepository, tasks: TaskRepository,
                                 now: Date = .now, calendar: Calendar = .app) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now),
              let all = try? tasks.tasks(in: week) else { return }
        for task in all where !task.isAllDay && task.start < now && task.status != .inProgress {
            let interval = task.displayInterval(in: calendar)
            // 实际专注比计划晚开始 5 分钟、少 10 分钟，演示「实际 vs 计划」的差别
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
            // 周一
            allDay("了解 Creative 链，完成第一天的任务", 0, nil, .urgent, .done),
            timed("阅读《第一性原理》", 0, 9, 30, 11, 0, .important, .done),
            timed("了解 Uniswap 协议", 0, 14, 0, 15, 30, .urgent),
            timed("学会使用区块浏览器", 0, 14, 30, 16, 0, .normal),
            // 周二
            allDay("了解链上数据", 1, nil, .important),
            timed("阅读《谈判技巧》", 1, 10, 0, 11, 0, .normal),
            timed("整理 DeFi 学习笔记", 1, 16, 0, 16, 45, .normal),
            // 周三：三个日程互相重叠，用来验证并排布局
            timed("了解交易所概念", 2, 9, 0, 12, 0, .urgent, .inProgress),
            timed("周会", 2, 10, 0, 11, 0, .normal, place: "3F 会议室"),
            timed("Code Review", 2, 10, 30, 11, 30, .important),
            // 周四到周五：跨天全天任务
            allDay("Creative 链黑客松", 3, 4, .important),
            timed("了解 Creative 链生态", 3, 15, 0, 16, 0, .normal),
            // 周五
            timed("复盘本周", 4, 20, 0, 21, 30, .important),
            // 周末
            timed("健身", 5, 10, 0, 11, 0, .normal, place: "健身房"),
            timed("规划下周主线任务", 6, 21, 0, 22, 0, .urgent),
        ]
    }
}
