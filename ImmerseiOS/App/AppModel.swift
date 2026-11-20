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
    let preferences: SecretaryPreferences
    private(set) var nudges: NudgeScheduler!
    private var lastMissedCheck: Date?
    private let dailyReview: DailyReviewScheduler
    private let autoFocus: AutoFocusScheduler?
    private var syncMonitor: SyncMonitor?

    /// The App Group shared with the widget and App Intents
    static let appGroup = "group.com.debugzhao.immerse"
    /// For App Intents running in the app process (Siri, widget buttons that open the app, Live Activity buttons)
    private(set) static var shared: AppModel?
    let liveActivities = LiveActivityController()

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
        preferences = SecretaryPreferences(defaults: isEphemeral ? UserDefaults(suiteName: "immerse.ephemeral") ?? .standard : .standard)
        nudges = NudgeScheduler(secretary: secretary, preferences: preferences, settings: settings,
                                notifications: notifications, focusEngine: focusEngine, calendar: calendar)
        installSecretaryHooks()
        // iOS suspends the app: due events start from the notification's 「开始专注」 button
        notifications.startsDueEventsByItself = false

        notifications.onAction = { [focusEngine] action in focusEngine.handle(action) }
        notifications.onAutoFocusAction = { [autoFocus] action, taskID in autoFocus?.handle(action, taskID: taskID) }
        notifications.onDailyReviewOpened = { [schedule] in schedule.isReviewPresented = true }
        notifications.onNudgeOpened = { [schedule] _ in schedule.isBriefingPresented = true }

        if !isEphemeral {
            syncMonitor = SyncMonitor(repository: repository) { [taskStore, focusEngine] in
                taskStore.reloadFromStore()
                focusEngine.reloadRecords()
            }
            syncMonitor?.start()
        }
        focusEngine.restore()
        dailyReview.start()
        autoFocus?.start(requestsPermission: false)
        if !isEphemeral { nudges.refresh() }
        Self.shared = self
        #if DEBUG
        applyScreenshotScene()
        #endif
    }

    #if DEBUG
    /// Screenshot mode (IMMERSE_SNAPSHOT=1) can open a given screen, since simctl can't tap:
    /// IMMERSE_TAB=schedule|planning|focus|stats, IMMERSE_MODE=day|threeDay|month,
    /// IMMERSE_SHEET=capture|briefing|review, IMMERSE_PROPOSAL=1 (plan the Inbox), IMMERSE_FOCUS=1 (start a session)
    private func applyScreenshotScene() {
        guard PersistenceController.isSnapshotMode else { return }
        let env = ProcessInfo.processInfo.environment
        schedule.suggestion = nil
        switch env["IMMERSE_TAB"] {
        case "planning": schedule.selectedTab = .planning
        case "focus": schedule.selectedTab = .focus
        case "stats": schedule.selectedTab = .stats
        default: break
        }
        if let mode = env["IMMERSE_MODE"].flatMap(ScheduleMode.init(rawValue:)) { schedule.mode = mode }
        if env["IMMERSE_FOCUS"] == "1", let task = taskStore.tasks(in: schedule.visibleInterval).first(where: { !$0.isAllDay }) {
            focusEngine.start(task)
        }
        let sheet = env["IMMERSE_SHEET"]
        Task { [schedule] in
            // Sheets can only be presented once the window is on screen
            try? await Task.sleep(for: .milliseconds(800))
            switch sheet {
            case "capture": schedule.isCapturePresented = true
            case "briefing": schedule.isBriefingPresented = true
            case "review": schedule.isReviewPresented = true
            default: break
            }
        }
        if env["IMMERSE_PROPOSAL"] == "1" {
            Task { [secretary, schedule] in
                schedule.showProposal(await secretary.planInbox(), secretary: secretary)
            }
        }
    }
    #endif

    /// Background app refresh: rebuild tomorrow's briefing with the latest data
    func backgroundRefresh() {
        taskStore.reloadFromStore()
        nudges.refresh()
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
        nudges.canSubmitBackgroundRefresh = true
        if !PersistenceController.isEphemeral { nudges.refresh() }
    }

    /// The secretary reacts to interruptions with a suggestion, never with a change (design §4)
    private func installSecretaryHooks() {
        let secretary = self.secretary, schedule = self.schedule
        // Quiet during focus: nudges that would land inside a session move to just after it
        focusEngine.onStarted = { [weak self] _ in self?.nudges.refresh() }
        focusEngine.onSessionEnded = { [weak self] state, reason in
            self?.nudges.refresh()
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
        guard !focusEngine.isActive, schedule.suggestion == nil, !PersistenceController.isSnapshotMode else { return }
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
