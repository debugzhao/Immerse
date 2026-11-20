import Foundation
import Observation
import OSLog

/// Focus engine: start / pause / extend / end a focus session, driving the countdown, notifications, and Do Not Disturb.
///
/// State machine: idle →(start)→ running ⇄(pause/resume)⇄ paused
///                                    running →(remaining ≤ 0)→ timeUp →(complete / extend)→ idle / running
/// At most one active focus session at any time.
@MainActor
@Observable
public final class FocusEngine {
    public enum Phase: Equatable {
        case idle
        case running
        case paused
        case timeUp
    }

    public private(set) var phase: Phase = .idle
    public private(set) var session: FocusSessionState?
    /// Refreshed every second; the UI reads it to update the countdown
    public private(set) var now: Date
    /// Start was tapped while a session already exists: waiting for the user to confirm the switch
    public var pendingSwitch: TaskSnapshot?
    /// Message shown when toggling Do Not Disturb fails
    public private(set) var dndWarning: String?
    /// Whether to show the full-screen immersive view
    public var isImmersivePresented = false
    /// Focus record version: incremented when a session ends; stats and calendar refresh based on it
    public private(set) var recordsRevision = 0

    @ObservationIgnored private let taskStore: TaskStore
    @ObservationIgnored private let repository: FocusSessionRepository
    @ObservationIgnored private let notifier: FocusNotifying
    @ObservationIgnored private let dnd: DoNotDisturbServicing
    @ObservationIgnored private let clock: () -> Date
    /// Progress reminder percentages (global setting, e.g. [50, 80])
    @ObservationIgnored private let progressMilestones: () -> [Int]
    /// Progress points already reminded for this session; not repeated after extending
    @ObservationIgnored private var notifiedMilestones: Set<Int> = []
    /// Callback after a session starts (used to start a countdown in "Clock")
    @ObservationIgnored public var onStarted: ((FocusSessionState) -> Void)?
    /// Called right after the time-up notification so the platform can grab attention (bounce the Dock icon on macOS)
    @ObservationIgnored public var onTimeUpAttention: (() -> Void)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Focus")
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// The moment time ran out (the record's end time uses this, not when the user tapped the button)
    @ObservationIgnored private var timeUpAt: Date?
    /// Extended duration (seconds), advanced from timestamps
    public static let extensionSeconds = 15 * 60

    public init(taskStore: TaskStore, repository: FocusSessionRepository, notifier: FocusNotifying,
         dnd: DoNotDisturbServicing, clock: @escaping () -> Date = { .now },
         progressMilestones: @escaping () -> [Int] = { [] }) {
        self.taskStore = taskStore
        self.repository = repository
        self.notifier = notifier
        self.dnd = dnd
        self.clock = clock
        self.progressMilestones = progressMilestones
        self.now = clock()
    }

    // MARK: - Derived state

    public var isActive: Bool { session != nil }
    public var isPaused: Bool { phase == .paused }
    public var remaining: TimeInterval { session?.remaining(at: now) ?? 0 }
    public var progress: Double { session?.progress(at: now) ?? 0 }
    public var remainingText: String { DurationText.countdown(remaining) }

    public func isFocusing(on taskID: UUID) -> Bool { session?.taskID == taskID }

    /// Finished focus records that overlap with interval
    public func records(in interval: DateInterval) -> [FocusRecord] {
        _ = recordsRevision
        do {
            return try repository.records(in: interval)
        } catch {
            logger.error("读取专注记录失败：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Start

    /// User taps "开始专注" (Start Focus): if another session exists, ask the user to confirm first
    public func requestStart(_ task: TaskSnapshot) {
        if let session, session.taskID != task.id {
            pendingSwitch = task
            return
        }
        if session?.taskID == task.id {
            if phase == .paused { resume() }
            return
        }
        start(task)
    }

    /// End the current session (counted as abandoned, not as early completion) and start a new one
    public func confirmSwitch() {
        guard let task = pendingSwitch else { return }
        pendingSwitch = nil
        finish(.abandoned)
        start(task)
    }

    /// End the current session (if any, counted as abandoned) and start `task` right away, without asking.
    /// Used when the user picks "switch" on a system notification, which is already an explicit choice.
    public func switchTo(_ task: TaskSnapshot, plannedSeconds: Int? = nil) {
        pendingSwitch = nil
        if session != nil { finish(.abandoned) }
        start(task, plannedSeconds: plannedSeconds)
    }

    /// - Parameter plannedSeconds: overrides the task's own focus length (auto-start uses the time left in the event)
    public func start(_ task: TaskSnapshot, plannedSeconds: Int? = nil) {
        let startedAt = clock()
        let state = FocusSessionState(taskID: task.id, taskTitle: task.displayTitle,
                                      startedAt: startedAt, plannedSeconds: plannedSeconds ?? task.focusMinutes * 60)
        guard persist(state) else { return }
        session = state
        phase = .running
        now = startedAt
        timeUpAt = nil
        notifiedMilestones = []
        // A goal spans many sessions: one focus run doesn't change its status
        if task.kind != .goal { taskStore.setStatusWithoutUndo(.inProgress, for: task.id) }

        Task {
            await notifier.requestAuthorizationIfNeeded()
            rescheduleBackup()
        }
        setDoNotDisturb(true)
        beginTicking()
        onStarted?(state)
    }

    // MARK: - Pause / resume / extend

    public func togglePause() {
        switch phase {
        case .running: pause()
        case .paused: resume()
        default: break
        }
    }

    public func pause() {
        guard phase == .running, var state = session else { return }
        state.pausedAt = clock()
        session = state
        phase = .paused
        persist(state)
        notifier.cancelBackup()
        notifier.cancelProgress()
    }

    public func resume() {
        guard phase == .paused, var state = session, let pausedAt = state.pausedAt else { return }
        let resumedAt = clock()
        state.pausedSeconds += Int(resumedAt.timeIntervalSince(pausedAt).rounded())
        state.pausedAt = nil
        session = state
        phase = .running
        now = resumedAt
        persist(state)
        rescheduleBackup()
    }

    /// +15 minutes. Extending after time is up returns to timing and re-enables Do Not Disturb
    public func extend(seconds: Int = FocusEngine.extensionSeconds) {
        guard var state = session else { return }
        let wasTimeUp = phase == .timeUp
        state.plannedSeconds += seconds
        if wasTimeUp {
            // Continue counting from the moment time ran out; the time the user spent hesitating does not count
            let current = clock()
            if let timeUpAt { state.pausedSeconds += Int(current.timeIntervalSince(timeUpAt).rounded()) }
            timeUpAt = nil
            phase = .running
            now = current
            setDoNotDisturb(true)
            beginTicking()
        }
        session = state
        persist(state)
        if phase == .running { rescheduleBackup() }
    }

    // MARK: - End

    /// Tap "标记完成" (Mark Complete) after time is up
    public func complete() {
        finish(.completed)
    }

    /// Finished early, before time is up
    public func finishEarly() {
        finish(.finishedEarly)
    }

    /// Abandon: the task status reverts to not started
    public func abandon() {
        finish(.abandoned)
    }

    private func finish(_ reason: FocusEndReason) {
        guard let state = session else { return }
        let endedAt = timeUpAt ?? clock()
        do {
            try repository.finish(state, endedAt: endedAt, reason: reason)
            recordsRevision += 1
        } catch {
            logger.error("保存专注记录失败：\(error.localizedDescription, privacy: .public)")
        }
        if taskStore.task(id: state.taskID)?.kind != .goal {
            taskStore.setStatusWithoutUndo(reason == .abandoned ? .todo : .done, for: state.taskID)
        }

        let wasTimeUp = phase == .timeUp
        session = nil
        phase = .idle
        timeUpAt = nil
        isImmersivePresented = false
        stopTicking()
        notifier.cancelBackup()
        notifier.cancelProgress()
        // Do Not Disturb was already turned off when time ran out
        if !wasTimeUp { setDoNotDisturb(false) }
    }

    // MARK: - Timer

    /// Called every second; also called immediately after waking from sleep
    public func tick() {
        now = clock()
        guard phase == .running, let session else { return }
        // Record the progress points already passed (the system delivers notifications on time; this only records)
        let percent = session.progress(at: now) * 100
        for milestone in progressMilestones() where Double(milestone) <= percent {
            notifiedMilestones.insert(milestone)
        }
        guard session.remaining(at: now) <= 0 else { return }
        handleTimeUp(at: session.plannedEnd)
    }

    private func handleTimeUp(at moment: Date) {
        guard let session else { return }
        phase = .timeUp
        notifier.cancelProgress()
        timeUpAt = min(moment, clock())
        stopTicking()
        let title = session.taskTitle
        // Must turn off Do Not Disturb before notifying, otherwise the notification itself would be silenced
        Task {
            await deactivateDoNotDisturb(timeout: .seconds(3))
            notifier.postTimeUp(title: title)
            onTimeUpAttention?()
        }
    }

    private func beginTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        if activity == nil {
            // Prevent App Nap from slowing the timer; does not block system sleep
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "专注计时")
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: - Restore

    /// Called at app launch: restores an unfinished session; if it is already overdue, runs the "time up" handling
    public func restore() {
        let state: FocusSessionState?
        do {
            state = try repository.activeSession()
        } catch {
            logger.error("读取进行中的专注失败：\(error.localizedDescription, privacy: .public)")
            state = nil
        }
        guard let state else {
            // No active session, but Do Not Disturb is still on from this app (e.g. it crashed last run): turn it off
            if dnd.isActivatedByApp { setDoNotDisturb(false) }
            return
        }
        session = state
        now = clock()
        if state.isPaused {
            phase = .paused
        } else if state.remaining(at: now) <= 0 {
            phase = .running
            handleTimeUp(at: state.plannedEnd)
        } else {
            phase = .running
            rescheduleBackup()
            beginTicking()
        }
    }

    // MARK: - Notification actions

    public func handle(_ action: FocusNotificationAction) {
        switch action {
        case .complete: phase == .timeUp ? complete() : finishEarly()
        case .extend: extend()
        }
    }

    // MARK: - Private

    /// Reschedule the "time up" fallback notification and progress reminders (called on start, resume, extend, restore)
    private func rescheduleBackup() {
        notifier.cancelBackup()
        notifier.cancelProgress()
        let current = clock()
        guard phase == .running, let session, let end = session.expectedEnd(at: current) else { return }
        notifier.scheduleBackup(at: end, title: session.taskTitle)

        var reminders: [FocusProgressReminder] = []
        for percent in Set(progressMilestones()).sorted() where (1..<100).contains(percent) {
            guard !notifiedMilestones.contains(percent),
                  let date = session.moment(atProgress: Double(percent) / 100, now: current) else { continue }
            if date <= current {
                // Already passed (e.g. when restoring after an app restart): do not resend
                notifiedMilestones.insert(percent)
                continue
            }
            reminders.append(FocusProgressReminder(
                percent: percent, date: date,
                remainingSeconds: session.plannedSeconds * (100 - percent) / 100))
        }
        if !reminders.isEmpty { notifier.scheduleProgress(reminders, title: session.taskTitle) }
    }

    @discardableResult
    private func persist(_ state: FocusSessionState) -> Bool {
        do {
            try repository.save(state)
            return true
        } catch {
            logger.error("保存专注状态失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func setDoNotDisturb(_ on: Bool) {
        guard dnd.isEnabledInSettings || (!on && dnd.isActivatedByApp) else { return }
        Task {
            do {
                if on { try await dnd.activate() } else { try await dnd.deactivate() }
                dndWarning = nil
            } catch {
                // A Do Not Disturb failure only shows a message; it does not affect timing
                dndWarning = on ? "开启勿扰失败：\(error.localizedDescription)" : "关闭勿扰失败：\(error.localizedDescription)"
                logger.error("\(self.dndWarning ?? "", privacy: .public)")
            }
        }
    }

    /// Turn off Do Not Disturb, waiting at most timeout; on timeout, cancel (the Shortcuts process gets killed) and stop waiting
    private func deactivateDoNotDisturb(timeout: Duration) async {
        guard dnd.isActivatedByApp else { return }
        let work = Task { try? await dnd.deactivate() }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        await work.value
        watchdog.cancel()
    }
}
