import Foundation
import Observation

/// 每日复盘提醒的内容（纯计算，便于测试）
enum DailyReview {
    static let maxListed = 5

    /// 下一次提醒的时刻：今天的提醒时间还没到就是今天，否则是明天
    static func nextFireDate(after now: Date, minutes: Int, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let fire = today.addingTimeInterval(TimeInterval(minutes * 60))
        if fire > now { return fire }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        return tomorrow.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// 那一天没有任务时返回 nil（不提醒）
    static func content(for tasks: [TaskSnapshot], calendar: Calendar) -> (title: String, body: String)? {
        guard !tasks.isEmpty else { return nil }
        let unfinished = tasks
            .filter { $0.status != .done }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
        guard !unfinished.isEmpty else {
            return ("今天的任务全部完成 🎉", "\(tasks.count) 个任务都搞定了，早点休息")
        }
        var lines = unfinished.prefix(maxListed).map { task in
            let time = task.isAllDay ? "全天" : TimeText.hhmm(task.start, calendar: calendar)
            return "· \(time)  \(task.displayTitle)"
        }
        if unfinished.count > maxListed {
            lines.append("…还有 \(unfinished.count - maxListed) 个")
        }
        return ("今天还有 \(unfinished.count) 个任务没完成", lines.joined(separator: "\n"))
    }
}

/// 安排每日复盘通知：用系统定时通知，App 没开着也会按时提醒。
/// 任务有变动、设置改了、每半小时都会重新安排一次，保证通知内容是最新的。
@MainActor
final class DailyReviewScheduler {
    private let taskStore: TaskStore
    private let settings: SettingsStore
    private let notifications: NotificationService
    private let calendar: Calendar
    private var refresher: Task<Void, Never>?

    init(taskStore: TaskStore, settings: SettingsStore, notifications: NotificationService, calendar: Calendar) {
        self.taskStore = taskStore
        self.settings = settings
        self.notifications = notifications
        self.calendar = calendar
    }

    func start() {
        reschedule()
        observeChanges()
        // 提醒发出后要安排第二天的；跨天、睡眠唤醒后也靠它补上
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                self?.reschedule()
            }
        }
    }

    func reschedule(now: Date = .now) {
        guard settings.dailyReviewEnabled else {
            notifications.cancelDailyReview()
            return
        }
        let fire = DailyReview.nextFireDate(after: now, minutes: settings.dailyReviewMinutes, calendar: calendar)
        guard let day = calendar.dateInterval(of: .day, for: fire),
              let content = DailyReview.content(for: taskStore.tasks(in: day), calendar: calendar) else {
            notifications.cancelDailyReview()
            return
        }
        notifications.scheduleDailyReview(at: fire, title: content.title, body: content.body, calendar: calendar)
    }

    private func observeChanges() {
        withObservationTracking {
            _ = taskStore.revision
            _ = settings.dailyReviewEnabled
            _ = settings.dailyReviewMinutes
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reschedule()
                self?.observeChanges()
            }
        }
    }
}
