import Foundation
import ImmerseAgent
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
    let ai: AISettings
    let secretary: Secretary
    let calendarSource: EventKitCalendarSource
    private var lastMissedCheck: Date?
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

        ai = AISettings(defaults: isEphemeral ? UserDefaults(suiteName: "immerse.ephemeral") ?? .standard : .standard,
                        secrets: isEphemeral ? InMemorySecretStore() : KeychainSecretStore())
        calendarSource = EventKitCalendarSource()
        secretary = Secretary(taskStore: taskStore, focusEngine: focusEngine, memories: memories, ai: ai,
                              calendar: calendar, externalCalendar: calendarSource)
        installSecretaryHooks()

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
        suggestReflowForMissedEvents()
        schedule.refreshClipboardHint()
    }

    /// The secretary reacts to interruptions with a suggestion, never with a change (design §4)
    private func installSecretaryHooks() {
        let secretary = self.secretary, schedule = self.schedule
        focusEngine.onSessionEnded = { state, reason in
            guard reason == .abandoned else { return }
            guard secretary.reflow() != nil else { return }
            schedule.suggestion = Suggestion(message: "放弃了「\(state.taskTitle)」，后面的安排要顺延吗？", actionTitle: "看看怎么排") {
                secretary.reflow()
            }
        }
        focusEngine.onExtended = { state, count in
            if count >= 2, secretary.ai.isAvailable, let task = secretary.context().tasks.first(where: { $0.id == state.taskID }) {
                schedule.suggestion = Suggestion(message: "「\(state.taskTitle)」已经延长 \(count) 次了，要拆成小一点的步骤吗？",
                                                 actionTitle: "帮我拆") { await secretary.splitProposal(task) }
                return
            }
            let end = state.plannedEnd
            guard secretary.reflow(from: end) != nil else { return }
            schedule.suggestion = Suggestion(message: "延长后会压到后面的安排，要顺延吗？", actionTitle: "看看怎么排") {
                secretary.reflow(from: end)
            }
        }
    }

    /// Events whose time has passed today but weren't done: offer to repack the rest of the day (at most hourly)
    private func suggestReflowForMissedEvents(now: Date = .now) {
        if let last = lastMissedCheck, now.timeIntervalSince(last) < 3600 { return }
        lastMissedCheck = now
        guard !focusEngine.isActive, schedule.suggestion == nil else { return }
        let calendar = schedule.calendar
        let today = calendar.startOfDay(for: now)
        let missed = taskStore.tasks(in: DateInterval(start: today, end: now))
            .filter { Reflow.isMovable($0) && $0.displayInterval(in: calendar).end <= now }
        guard !missed.isEmpty, secretary.reflow(from: now) != nil else { return }
        let secretary = self.secretary
        schedule.suggestion = Suggestion(message: "有 \(missed.count) 个日程时间已过还没做，重排今天剩下的时间？", actionTitle: "重排") {
            secretary.reflow(from: .now)
        }
    }
}
