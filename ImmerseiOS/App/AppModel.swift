import Foundation
import ImmerseCore
import Observation
import SwiftData
import UIKit

/// iOS dependency-injection root: creates and owns the shared stores and system services.
/// Mirrors the macOS `AppEnvironment`, minus the Mac-only pieces (menu bar, Shortcuts DND, update checker).
@MainActor
final class AppModel {
    let taskStore: TaskStore
    let settings: SettingsStore
    let focusEngine: FocusEngine
    let notifications: NotificationService
    let schedule: ScheduleState
    let memories: MemoryRepository
    let container: ModelContainer?
    private let dailyReview: DailyReviewScheduler
    private let autoFocus: AutoFocusScheduler?
    private var syncMonitor: SyncMonitor?

    /// The App Group shared with the widget and App Intents
    static let appGroup = "group.com.debugzhao.immerse"

    init(calendar: Calendar = .app) {
        let isEphemeral = PersistenceController.isEphemeral
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer(storeURL: try PersistenceController.defaultStoreURL(appGroup: Self.appGroup))
        } catch {
            fatalError("无法打开本地数据库：\(error)")
        }
        self.container = container
        let repository = SwiftDataTaskRepository(container: container, calendar: calendar)
        let focusRepository = SwiftDataFocusSessionRepository(tasks: repository)
        #if DEBUG
        if PersistenceController.isSnapshotMode {
            try? repository.insert(SampleData.make(around: .now))
            SampleData.seedFocusHistory(focusRepository, tasks: repository)
        }
        #endif
        memories = SwiftDataMemoryRepository(context: container.mainContext)

        taskStore = TaskStore(repository: repository)
        settings = SettingsStore(defaults: isEphemeral ? UserDefaults(suiteName: "immerse.ephemeral") ?? .standard : .standard)
        notifications = NotificationService(isSilenced: isEphemeral)
        let settings = self.settings
        focusEngine = FocusEngine(taskStore: taskStore, repository: focusRepository, notifier: notifications,
                                  dnd: NoopDoNotDisturbService(), progressMilestones: { settings.progressMilestones })
        schedule = ScheduleState(calendar: calendar)
        dailyReview = DailyReviewScheduler(
            taskStore: taskStore, settings: settings, notifications: notifications, calendar: calendar,
            behindGoals: { [taskStore, focusEngine] now in
                let goals = GoalQueries.active(taskStore: taskStore, calendar: calendar, now: now)
                return GoalQueries.behind(goals, taskStore: taskStore, focusEngine: focusEngine, calendar: calendar, now: now)
                    .map { goal in
                        let progress = GoalQueries.progress(of: goal, taskStore: taskStore, focusEngine: focusEngine,
                                                            calendar: calendar, now: now)
                        return "\(goal.displayTitle) \(progress.percent)%（还剩 \(progress.daysLeft) 天）"
                    }
            })
        autoFocus = isEphemeral ? nil : AutoFocusScheduler(
            taskStore: taskStore, focusEngine: focusEngine, settings: settings, notifier: notifications, calendar: calendar)

        notifications.onAction = { [focusEngine] action in focusEngine.handle(action) }
        notifications.onAutoFocusAction = { [autoFocus] action, taskID in autoFocus?.handle(action, taskID: taskID) }
        notifications.onDailyReviewOpened = { [schedule] in schedule.selectedTab = .planning }

        if !isEphemeral {
            syncMonitor = SyncMonitor(repository: repository) { [taskStore, focusEngine] in
                taskStore.reloadFromStore()
                focusEngine.reloadRecords()
            }
            syncMonitor?.start()
        }
        focusEngine.restore()
        dailyReview.start()
        autoFocus?.start()
    }

    /// Back in the foreground: timers were suspended, so catch up on everything that is time-driven
    func didBecomeActive() {
        // A widget or App Intent may have written the shared store while the app was in the background
        taskStore.reloadFromStore()
        focusEngine.tick()
        dailyReview.reschedule()
        autoFocus?.evaluate()
    }
}
