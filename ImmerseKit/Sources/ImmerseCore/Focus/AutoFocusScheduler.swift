import Foundation
import Observation
import OSLog

/// Rules for starting focus automatically when a timed event begins (pure computation, easy to test).
public enum AutoFocus {
    /// The "starting soon" system notification fires this long before the event
    public static let leadTime: TimeInterval = 60
    /// "推迟 5 分钟" (Snooze 5 minutes) on the notification
    public static let snoozeInterval: TimeInterval = 5 * 60
    /// Less time than this left in the event: not worth starting
    public static let minimumSeconds = 60
    /// Grace period after the start time that still counts as "on time" (the check runs every few seconds)
    public static let onTimeGrace: TimeInterval = 60

    public struct Plan: Equatable {
        public let task: TaskSnapshot
        public let plannedSeconds: Int
    }

    /// Only timed calendar events take part; all-day events, Inbox ideas, goals and finished events are left alone
    public static func isEligible(_ task: TaskSnapshot) -> Bool {
        task.kind == .event && !task.isAllDay && task.status != .done
    }

    /// Focus length when starting `task` at `now`.
    /// On time: the planned focus length if one is set, otherwise until the event ends.
    /// Late (snoozed, or caught up after the app was closed / the Mac slept): never runs past the event's end.
    /// nil when less than a minute is left.
    public static func plannedSeconds(for task: TaskSnapshot, at now: Date, calendar: Calendar) -> Int? {
        let end = task.displayInterval(in: calendar).end
        let remaining = Int(end.timeIntervalSince(now))
        let isLate = now.timeIntervalSince(task.start) > onTimeGrace
        let seconds: Int
        if let planned = task.plannedMinutes, planned > 0 {
            seconds = isLate ? min(planned * 60, remaining) : planned * 60
        } else {
            seconds = remaining
        }
        return seconds >= minimumSeconds ? seconds : nil
    }

    /// The event that should start now: in progress at `now`, not handled yet and not snoozed past `now`.
    /// With overlapping events the one that started most recently wins.
    public static func due(in tasks: [TaskSnapshot], at now: Date, calendar: Calendar,
                    isHandled: (TaskSnapshot) -> Bool, snoozedUntil: (TaskSnapshot) -> Date?) -> Plan? {
        tasks
            .filter { isEligible($0) && $0.start <= now && !isHandled($0) }
            .filter { task in snoozedUntil(task).map { now >= $0 } ?? true }
            .sorted { $0.start > $1.start }
            .lazy
            .compactMap { task in plannedSeconds(for: task, at: now, calendar: calendar).map { Plan(task: task, plannedSeconds: $0) } }
            .first
    }

    /// The next event that will start after `now` (for the "starting soon" notification)
    public static func next(in tasks: [TaskSnapshot], after now: Date, isHandled: (TaskSnapshot) -> Bool) -> TaskSnapshot? {
        tasks
            .filter { isEligible($0) && $0.start > now && !isHandled($0) }
            .min { $0.start < $1.start }
    }

    /// Identifies one occurrence of an event. Includes the start time, so moving the event makes it eligible again
    public static func key(for task: TaskSnapshot) -> String {
        "\(task.id.uuidString)@\(Int(task.start.timeIntervalSince1970))"
    }
}

/// Actions on the auto-focus system notifications
public enum AutoFocusAction: String {
    /// "Starting soon": push the automatic start back 5 minutes
    case snooze = "AUTO_FOCUS_SNOOZE_5"
    /// "Starting soon": don't start this event automatically
    case skip = "AUTO_FOCUS_SKIP"
    /// "Started": abandon the session that was just started
    case abandon = "AUTO_FOCUS_ABANDON"
    /// "Another session is running": end it and focus on this event instead
    case switchFocus = "AUTO_FOCUS_SWITCH"
    /// "Starting soon" / "it's time": start now. On iOS the app is suspended at the start time, so this button
    /// on the notification is how a scheduled event gets started
    case startNow = "AUTO_FOCUS_START"
}

/// System notifications used by auto-focus
@MainActor
public protocol AutoFocusNotifying: AnyObject {
    func requestAuthorizationIfNeeded() async
    func scheduleAutoFocusUpcoming(taskID: UUID, title: String, start: Date, at date: Date)
    func cancelAutoFocusUpcoming()
    func postAutoFocusStarted(taskID: UUID, title: String, plannedSeconds: Int)
    func postAutoFocusConflict(taskID: UUID, title: String, currentTitle: String)
}

/// Starts focus automatically when a timed event begins and marks the event "in progress".
///
/// - Before the start: a system notification one minute ahead, with "Snooze 5 minutes" / "Skip".
/// - At the start: starts focus (the task becomes in progress) and posts a system notification.
/// - Another session already running: it is not interrupted; the event is marked in progress and a notification offers to switch.
/// - App closed or Mac asleep at the start: caught up on the next launch / wake while the event is still going, for the time left.
/// Each event occurrence is handled once (persisted), so abandoning an auto-started session doesn't restart it.
@MainActor
public final class AutoFocusScheduler {
    private let taskStore: TaskStore
    private let focusEngine: FocusEngine
    private let settings: SettingsStore
    private let notifier: AutoFocusNotifying
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let clock: () -> Date
    private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "AutoFocus")

    /// Event occurrence key → when it was handled (started, skipped, or found busy)
    private var handled: [String: Double]
    /// Event occurrence key → snoozed until
    private var snoozes: [String: Date] = [:]
    /// The "starting soon" notification currently queued, so it is only replaced when it changes
    private var queuedUpcoming: (key: String, fire: Date)?
    private var loop: Task<Void, Never>?

    public static let handledKey = "autoFocus.handled"
    /// Handled records older than this are dropped
    private static let retention: TimeInterval = 3 * 86400
    /// Events can't usefully start more than this long before now; bounds the query
    private static let lookback: TimeInterval = 86400

    public init(taskStore: TaskStore, focusEngine: FocusEngine, settings: SettingsStore, notifier: AutoFocusNotifying,
         defaults: UserDefaults = .standard, calendar: Calendar = .app, clock: @escaping () -> Date = { .now }) {
        self.taskStore = taskStore
        self.focusEngine = focusEngine
        self.settings = settings
        self.notifier = notifier
        self.defaults = defaults
        self.calendar = calendar
        self.clock = clock
        handled = (defaults.dictionary(forKey: Self.handledKey) as? [String: Double]) ?? [:]
    }

    /// Starts checking: right away, whenever tasks or the setting change, and every few seconds.
    /// - Parameter requestsPermission: macOS asks for notification permission at launch; iOS waits until the user
    ///   first schedules or starts something (asking out of context is an App Review red flag)
    public func start(requestsPermission: Bool = true) {
        if requestsPermission { Task { await notifier.requestAuthorizationIfNeeded() } }
        evaluate()
        observeChanges()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.secondsUntilNextCheck() ?? 30
                try? await Task.sleep(for: .seconds(delay))
                self?.evaluate()
            }
        }
    }

    /// Checks once: starts a due event and refreshes the "starting soon" notification.
    /// Also called on wake from sleep, so a start missed while asleep is caught up.
    public func evaluate() {
        guard settings.autoFocusEnabled else {
            cancelUpcoming()
            return
        }
        let now = clock()
        pruneHandled(now: now)
        let tasks = taskStore.tasks(in: DateInterval(start: now.addingTimeInterval(-Self.lookback), duration: 2 * Self.lookback))

        if let plan = AutoFocus.due(in: tasks, at: now, calendar: calendar,
                                    isHandled: isHandled, snoozedUntil: { self.snoozes[AutoFocus.key(for: $0)] }) {
            begin(plan)
        }
        refreshUpcoming(tasks: tasks, now: now)
    }

    /// The user tapped a button on one of the auto-focus notifications
    public func handle(_ action: AutoFocusAction, taskID: UUID) {
        guard let task = taskStore.task(id: taskID) else { return }
        let key = AutoFocus.key(for: task)
        let now = clock()
        switch action {
        case .snooze:
            snoozes[key] = max(task.start, now).addingTimeInterval(AutoFocus.snoozeInterval)
        case .skip:
            markHandled(key, now: now)
        case .abandon:
            if focusEngine.isFocusing(on: taskID) { focusEngine.abandon() }
        case .switchFocus:
            guard !focusEngine.isFocusing(on: taskID),
                  let seconds = AutoFocus.plannedSeconds(for: task, at: now, calendar: calendar) else { break }
            focusEngine.switchTo(task, plannedSeconds: seconds)
        case .startNow:
            guard !focusEngine.isFocusing(on: taskID) else { break }
            markHandled(key, now: now)
            // Before the start: the full planned length; after it: what's left of the event
            let seconds = now < task.start ? task.focusMinutes * 60
                : AutoFocus.plannedSeconds(for: task, at: now, calendar: calendar) ?? task.focusMinutes * 60
            focusEngine.switchTo(task, plannedSeconds: seconds)
        }
        evaluate()
    }

    // MARK: - Private

    private func begin(_ plan: AutoFocus.Plan) {
        let task = plan.task
        let now = clock()
        markHandled(AutoFocus.key(for: task), now: now)
        snoozes[AutoFocus.key(for: task)] = nil

        if focusEngine.isFocusing(on: task.id) { return }
        if let current = focusEngine.session {
            // Don't interrupt: the event has begun, so it is in progress, and the user decides whether to switch
            taskStore.setStatusWithoutUndo(.inProgress, for: task.id)
            notifier.postAutoFocusConflict(taskID: task.id, title: task.displayTitle, currentTitle: current.taskTitle)
            logger.info("日程已开始但有专注在进行，未打断：\(task.displayTitle, privacy: .public)")
            return
        }
        focusEngine.start(task, plannedSeconds: plan.plannedSeconds)
        notifier.postAutoFocusStarted(taskID: task.id, title: task.displayTitle, plannedSeconds: plan.plannedSeconds)
        logger.info("到点自动开始专注：\(task.displayTitle, privacy: .public)")
    }

    private func refreshUpcoming(tasks: [TaskSnapshot], now: Date) {
        guard let next = AutoFocus.next(in: tasks, after: now, isHandled: isHandled) else {
            cancelUpcoming()
            return
        }
        let key = AutoFocus.key(for: next)
        let fire = next.start.addingTimeInterval(-AutoFocus.leadTime)
        // Too close to notify ahead: the start notification will follow in a moment
        guard fire > now.addingTimeInterval(1), snoozes[key] == nil else {
            if queuedUpcoming?.key != key { cancelUpcoming() }
            return
        }
        if let queuedUpcoming, queuedUpcoming.key == key, queuedUpcoming.fire == fire { return }
        notifier.scheduleAutoFocusUpcoming(taskID: next.id, title: next.displayTitle, start: next.start, at: fire)
        queuedUpcoming = (key, fire)
    }

    private func cancelUpcoming() {
        notifier.cancelAutoFocusUpcoming()
        queuedUpcoming = nil
    }

    private func isHandled(_ task: TaskSnapshot) -> Bool {
        handled[AutoFocus.key(for: task)] != nil
    }

    private func markHandled(_ key: String, now: Date) {
        handled[key] = now.timeIntervalSince1970
        defaults.set(handled, forKey: Self.handledKey)
    }

    private func pruneHandled(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        let kept = handled.filter { $0.value >= cutoff }
        guard kept.count != handled.count else { return }
        handled = kept
        defaults.set(handled, forKey: Self.handledKey)
    }

    /// Sleep until the next event start or snooze end, checking at least every 30 s (and never more than once a second)
    private func secondsUntilNextCheck() -> Double {
        let now = clock()
        let tasks = taskStore.tasks(in: DateInterval(start: now, duration: 60))
        let candidates = tasks.filter(AutoFocus.isEligible).map(\.start) + Array(snoozes.values)
        let next = candidates.filter { $0 > now }.min().map { $0.timeIntervalSince(now) } ?? 30
        return min(max(next, 1), 30)
    }

    private func observeChanges() {
        withObservationTracking {
            _ = taskStore.revision
            _ = settings.autoFocusEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.evaluate()
                self?.observeChanges()
            }
        }
    }
}
