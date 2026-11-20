import Foundation

/// Dependency-injection root: creates and owns all stores and system services; the app entry injects them into the view environment.
@MainActor
final class AppEnvironment {
    let taskStore: TaskStore
    let calendarStore: CalendarStore
    let settings: SettingsStore
    let focusEngine: FocusEngine
    let notifications: NotificationService
    let shortcutsDND: ShortcutsDoNotDisturbService
    let clockTimer: ClockTimerService
    let updateChecker: UpdateChecker
    private let dailyReview: DailyReviewScheduler
    /// nil for tests / screenshots, so sample events never start a session on their own
    private let autoFocus: AutoFocusScheduler?
    private var powerMonitor: PowerMonitor?

    /// - Parameter isEphemeral: tests / screenshots: no system notifications, no toggling of the real Do Not Disturb
    init(repository: TaskRepository, focusRepository: FocusSessionRepository,
         isEphemeral: Bool = false, calendar: Calendar = .app) {
        taskStore = TaskStore(repository: repository)
        calendarStore = CalendarStore(calendar: calendar)
        settings = SettingsStore(defaults: isEphemeral ? UserDefaults(suiteName: "immerse.ephemeral") ?? .standard : .standard)
        notifications = NotificationService(isSilenced: isEphemeral)
        shortcutsDND = ShortcutsDoNotDisturbService(settings: settings)
        let dnd: DoNotDisturbServicing = isEphemeral ? NoopDoNotDisturbService() : shortcutsDND
        let settings = self.settings
        focusEngine = FocusEngine(taskStore: taskStore, repository: focusRepository,
                                  notifier: notifications, dnd: dnd,
                                  progressMilestones: { settings.progressMilestones })
        clockTimer = ClockTimerService(settings: settings)
        updateChecker = UpdateChecker(defaults: isEphemeral ? UserDefaults(suiteName: "immerse.ephemeral") ?? .standard : .standard)
        dailyReview = DailyReviewScheduler(
            taskStore: taskStore, settings: settings, notifications: notifications, calendar: calendar,
            behindGoals: { [taskStore, focusEngine] _ in
                taskStore.goals()
                    .filter { $0.status != .done && $0.isActiveGoal(now: .now, calendar: calendar) }
                    .compactMap { goal in
                        let progress = goalProgress(goal, taskStore: taskStore, focusEngine: focusEngine, calendar: calendar)
                        return progress.isBehind ? "\(goal.displayTitle) \(progress.percent)%（还剩 \(progress.daysLeft) 天）" : nil
                    }
            })

        autoFocus = isEphemeral ? nil : AutoFocusScheduler(
            taskStore: taskStore, focusEngine: focusEngine, settings: settings,
            notifier: notifications, calendar: calendar)

        notifications.onAction = { [focusEngine] action in focusEngine.handle(action) }
        notifications.onAutoFocusAction = { [autoFocus] action, taskID in autoFocus?.handle(action, taskID: taskID) }
        // The review mentions the Inbox and lagging goals: open the planning panel so they're right there
        notifications.onDailyReviewOpened = {
            UserDefaults.standard.set(true, forKey: PlanningPanel.visibilityKey)
        }
        if !isEphemeral {
            focusEngine.onStarted = { [clockTimer] session in
                clockTimer.startIfEnabled(minutes: max(session.plannedSeconds / 60, 1))
            }
        }
        powerMonitor = PowerMonitor { [focusEngine, dailyReview, autoFocus] in
            focusEngine.tick()
            dailyReview.reschedule()
            // Catch up an event that began while the Mac was asleep
            autoFocus?.evaluate()
        }
        // Restore first: an event whose session survived a relaunch must not be started a second time
        focusEngine.restore()
        dailyReview.start()
        autoFocus?.start()
        if !isEphemeral {
            Task { [updateChecker] in await updateChecker.checkAutomaticallyIfDue() }
        }
    }
}
