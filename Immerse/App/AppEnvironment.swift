import Foundation

/// 依赖注入的根：统一创建并持有所有 Store，App 入口把它们注入到视图环境里。
@MainActor
final class AppEnvironment {
    let taskStore: TaskStore
    let calendarStore: CalendarStore

    init(repository: TaskRepository, calendar: Calendar = .app) {
        taskStore = TaskStore(repository: repository)
        calendarStore = CalendarStore(calendar: calendar)
    }
}
