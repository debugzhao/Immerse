import BackgroundTasks
import Foundation
import ImmerseAgent
import ImmerseCore

/// Keeps the secretary's proactive notifications for today and tomorrow scheduled with fresh content.
/// iOS doesn't keep the app running, so everything is pre-scheduled as local notifications; refreshes happen
/// on launch, when returning to the foreground, when a session starts or ends, and in background app refresh.
@MainActor
final class NudgeScheduler {
    static let refreshTaskID = "com.debugzhao.immerse.refresh"

    private let secretary: Secretary
    private let preferences: SecretaryPreferences
    private let settings: SettingsStore
    private let notifications: NotificationService
    private let focusEngine: FocusEngine
    private let calendar: Calendar
    /// BGTaskScheduler asserts if a request is submitted before SwiftUI registered the `.backgroundTask` handler,
    /// which happens when the scene is built — so submitting waits until the app has become active once
    var canSubmitBackgroundRefresh = false
    private var scheduledIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "secretary.scheduledNudges") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "secretary.scheduledNudges") }
    }

    init(secretary: Secretary, preferences: SecretaryPreferences, settings: SettingsStore,
         notifications: NotificationService, focusEngine: FocusEngine, calendar: Calendar) {
        self.secretary = secretary
        self.preferences = preferences
        self.settings = settings
        self.notifications = notifications
        self.focusEngine = focusEngine
        self.calendar = calendar
    }

    func refresh(now: Date = .now) {
        notifications.cancelNudges(ids: scheduledIDs)
        guard !preferences.isSystemFocusQuiet else {
            scheduledIDs = []
            return
        }
        let context = secretary.context(now: now)
        let insights = secretary.insights(now: now)
        var quiet: [DateInterval] = []
        if let session = focusEngine.session, let end = session.expectedEnd(at: now) {
            quiet.append(DateInterval(start: min(session.startedAt, now), end: max(end, now)))
        }
        var picked: [Nudge] = []
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            var dayContext = context
            dayContext.now = max(now, day)
            let dayInsights = offset == 0 ? insights : secretary.insights(now: day.addingTimeInterval(6 * 3600))
            let candidates = NudgePlanner.candidates(for: day, context: dayContext, insights: dayInsights,
                                                     morningMinutes: preferences.morningBriefingEnabled ? preferences.morningBriefingMinutes : nil)
            picked += NudgePlanner.select(candidates, budget: preferences.dailyNudgeBudget, reviewCounts: settings.dailyReviewEnabled,
                                          quiet: quiet, now: now, calendar: calendar)
        }
        for nudge in picked {
            notifications.scheduleNudge(id: nudge.id, at: nudge.fireDate, title: nudge.title, body: nudge.body,
                                        isPassive: nudge.isPassive, calendar: calendar)
        }
        scheduledIDs = picked.map(\.id)
        scheduleBackgroundRefresh(now: now)
    }

    /// Ask iOS to wake the app early tomorrow so the morning briefing reflects overnight changes (best effort)
    private func scheduleBackgroundRefresh(now: Date) {
        guard canSubmitBackgroundRefresh, !PersistenceController.isEphemeral else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        request.earliestBeginDate = calendar.date(byAdding: .hour, value: 6, to: tomorrow)
        try? BGTaskScheduler.shared.submit(request)
    }
}
