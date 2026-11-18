import Foundation

/// 依赖注入的根：统一创建并持有所有 Store 和系统服务，App 入口把它们注入到视图环境里。
@MainActor
final class AppEnvironment {
    let taskStore: TaskStore
    let calendarStore: CalendarStore
    let settings: SettingsStore
    let focusEngine: FocusEngine
    let notifications: NotificationService
    let shortcutsDND: ShortcutsDoNotDisturbService
    private var powerMonitor: PowerMonitor?

    /// - Parameter isEphemeral: 测试 / 截图：不发系统通知、不切换真实的勿扰
    init(repository: TaskRepository, focusRepository: FocusSessionRepository,
         isEphemeral: Bool = false, calendar: Calendar = .app) {
        taskStore = TaskStore(repository: repository)
        calendarStore = CalendarStore(calendar: calendar)
        settings = SettingsStore(defaults: isEphemeral ? UserDefaults(suiteName: "immerse.ephemeral") ?? .standard : .standard)
        notifications = NotificationService(isSilenced: isEphemeral)
        shortcutsDND = ShortcutsDoNotDisturbService(settings: settings)
        let dnd: DoNotDisturbServicing = isEphemeral ? NoopDoNotDisturbService() : shortcutsDND
        focusEngine = FocusEngine(taskStore: taskStore, repository: focusRepository,
                                  notifier: notifications, dnd: dnd)

        notifications.onAction = { [focusEngine] action in focusEngine.handle(action) }
        powerMonitor = PowerMonitor { [focusEngine] in focusEngine.tick() }
        focusEngine.restore()
    }
}
