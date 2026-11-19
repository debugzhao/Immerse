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
        dailyReview = DailyReviewScheduler(taskStore: taskStore, settings: settings,
                                           notifications: notifications, calendar: calendar)

        notifications.onAction = { [focusEngine] action in focusEngine.handle(action) }
        if !isEphemeral {
            focusEngine.onStarted = { [clockTimer] session in
                clockTimer.startIfEnabled(minutes: max(session.plannedSeconds / 60, 1))
            }
        }
        powerMonitor = PowerMonitor { [focusEngine, dailyReview] in
            focusEngine.tick()
            dailyReview.reschedule()
        }
        focusEngine.restore()
        dailyReview.start()
        if !isEphemeral {
            Task { [updateChecker] in await updateChecker.checkAutomaticallyIfDue() }
        }
    }
}
