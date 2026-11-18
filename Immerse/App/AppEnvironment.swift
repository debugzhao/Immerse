import Foundation

/// 依赖注入的根：统一创建并持有所有 Store 和系统服务，App 入口把它们注入到视图环境里。
@MainActor
final class AppEnvironment {
    let taskStore: TaskStore
    let calendarStore: CalendarStore
    let focusEngine: FocusEngine
    let notifications: NotificationService
    let dnd: DoNotDisturbServicing
    private var powerMonitor: PowerMonitor?

    init(repository: TaskRepository, focusRepository: FocusSessionRepository,
         dnd: DoNotDisturbServicing, notificationsSilenced: Bool = false, calendar: Calendar = .app) {
        taskStore = TaskStore(repository: repository)
        calendarStore = CalendarStore(calendar: calendar)
        notifications = NotificationService(isSilenced: notificationsSilenced)
        self.dnd = dnd
        focusEngine = FocusEngine(taskStore: taskStore, repository: focusRepository,
                                  notifier: notifications, dnd: dnd)

        notifications.onAction = { [focusEngine] action in focusEngine.handle(action) }
        powerMonitor = PowerMonitor { [focusEngine] in focusEngine.tick() }
        focusEngine.restore()
    }
}
