import Foundation
import Observation

/// Content of the daily review reminder (pure computation, easy to test)
enum DailyReview {
    static let maxListed = 5

    /// Next reminder time: today if today's reminder time hasn't passed, otherwise tomorrow
    static func nextFireDate(after now: Date, minutes: Int, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let fire = today.addingTimeInterval(TimeInterval(minutes * 60))
        if fire > now { return fire }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)
        return tomorrow.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Returns nil when that day has no tasks (no reminder)
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

/// Schedules the daily review notification: uses a system scheduled notification so it fires on time even if the app isn't running.
/// Rescheduled whenever tasks change, settings change, and every half hour, to keep the notification content current.
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
        // After a reminder fires, schedule the next day's; this also catches up across day changes and wake from sleep
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
