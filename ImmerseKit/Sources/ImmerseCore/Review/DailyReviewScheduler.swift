import Foundation
import Observation

/// Schedules the daily review notification: uses a system scheduled notification so it fires on time even if the app isn't running.
/// Rescheduled whenever tasks change, settings change, and every half hour, to keep the notification content current.
@MainActor
public final class DailyReviewScheduler {
    private let taskStore: TaskStore
    private let settings: SettingsStore
    private let notifications: NotificationService
    private let calendar: Calendar
    private var refresher: Task<Void, Never>?

    /// Lines for goals that are behind schedule at the given moment
    private let behindGoals: (Date) -> [String]

    public init(taskStore: TaskStore, settings: SettingsStore, notifications: NotificationService, calendar: Calendar,
         behindGoals: @escaping (Date) -> [String] = { _ in [] }) {
        self.behindGoals = behindGoals
        self.taskStore = taskStore
        self.settings = settings
        self.notifications = notifications
        self.calendar = calendar
    }

    public func start() {
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

    public func reschedule(now: Date = .now) {
        guard settings.dailyReviewEnabled else {
            notifications.cancelDailyReview()
            return
        }
        let fire = DailyReview.nextFireDate(after: now, minutes: settings.dailyReviewMinutes, calendar: calendar)
        guard let day = calendar.dateInterval(of: .day, for: fire),
              let content = DailyReview.content(
                for: taskStore.tasks(in: day), behindGoals: behindGoals(fire),
                inbox: DailyReview.InboxSummary(ideas: taskStore.ideas(), now: fire, calendar: calendar),
                calendar: calendar) else {
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
