import AppKit
import Foundation
import Observation
import OSLog

/// 专注引擎：开始 / 暂停 / 延长 / 结束一次专注，驱动倒计时、通知和勿扰。
///
/// 状态机：idle →(start)→ running ⇄(pause/resume)⇄ paused
///                         running →(剩余 ≤ 0)→ timeUp →(完成 / 延长)→ idle / running
/// 任何时候最多一个进行中的专注。
@MainActor
@Observable
final class FocusEngine {
    enum Phase: Equatable {
        case idle
        case running
        case paused
        case timeUp
    }

    private(set) var phase: Phase = .idle
    private(set) var session: FocusSessionState?
    /// 每秒刷新一次，界面读取它来更新倒计时
    private(set) var now: Date
    /// 已有专注时又点了开始：等待用户确认是否切换
    var pendingSwitch: TaskSnapshot?
    /// 勿扰开关失败时的提示
    private(set) var dndWarning: String?
    /// 是否显示全屏沉浸视图
    var isImmersivePresented = false
    /// 专注记录版本号：有专注结束时递增，统计和日历据此刷新
    private(set) var recordsRevision = 0

    @ObservationIgnored private let taskStore: TaskStore
    @ObservationIgnored private let repository: FocusSessionRepository
    @ObservationIgnored private let notifier: FocusNotifying
    @ObservationIgnored private let dnd: DoNotDisturbServicing
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Focus")
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// 时间到的那一刻（专注记录的结束时间用它，而不是用户点按钮的时间）
    @ObservationIgnored private var timeUpAt: Date?
    /// 由时间戳推进的延长时长（秒）
    static let extensionSeconds = 15 * 60

    init(taskStore: TaskStore, repository: FocusSessionRepository, notifier: FocusNotifying,
         dnd: DoNotDisturbServicing, clock: @escaping () -> Date = { .now }) {
        self.taskStore = taskStore
        self.repository = repository
        self.notifier = notifier
        self.dnd = dnd
        self.clock = clock
        self.now = clock()
    }

    // MARK: - 派生状态

    var isActive: Bool { session != nil }
    var isPaused: Bool { phase == .paused }
    var remaining: TimeInterval { session?.remaining(at: now) ?? 0 }
    var progress: Double { session?.progress(at: now) ?? 0 }
    var remainingText: String { DurationText.countdown(remaining) }

    func isFocusing(on taskID: UUID) -> Bool { session?.taskID == taskID }

    /// 与 interval 有交集的已结束专注记录
    func records(in interval: DateInterval) -> [FocusRecord] {
        _ = recordsRevision
        do {
            return try repository.records(in: interval)
        } catch {
            logger.error("读取专注记录失败：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - 开始

    /// 用户点「开始专注」：已有其它专注时先让用户确认
    func requestStart(_ task: TaskSnapshot) {
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

    /// 结束当前专注（算提前完成前的放弃），开始新的
    func confirmSwitch() {
        guard let task = pendingSwitch else { return }
        pendingSwitch = nil
        finish(.abandoned)
        start(task)
    }

    func start(_ task: TaskSnapshot) {
        let startedAt = clock()
        let state = FocusSessionState(taskID: task.id, taskTitle: task.displayTitle,
                                      startedAt: startedAt, plannedSeconds: task.focusMinutes * 60)
        guard persist(state) else { return }
        session = state
        phase = .running
        now = startedAt
        timeUpAt = nil
        taskStore.setStatusWithoutUndo(.inProgress, for: task.id)

        Task {
            await notifier.requestAuthorizationIfNeeded()
            rescheduleBackup()
        }
        setDoNotDisturb(true)
        beginTicking()
    }

    // MARK: - 暂停 / 继续 / 延长

    func togglePause() {
        switch phase {
        case .running: pause()
        case .paused: resume()
        default: break
        }
    }

    func pause() {
        guard phase == .running, var state = session else { return }
        state.pausedAt = clock()
        session = state
        phase = .paused
        persist(state)
        notifier.cancelBackup()
    }

    func resume() {
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

    /// +15 分钟。时间到之后延长会回到计时，并重新开启勿扰
    func extend(seconds: Int = FocusEngine.extensionSeconds) {
        guard var state = session else { return }
        let wasTimeUp = phase == .timeUp
        state.plannedSeconds += seconds
        if wasTimeUp {
            // 从时间到的那一刻接着算，用户犹豫的这段时间不计入
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

    // MARK: - 结束

    /// 时间到后点「标记完成」
    func complete() {
        finish(.completed)
    }

    /// 时间没到，提前完成
    func finishEarly() {
        finish(.finishedEarly)
    }

    /// 放弃：任务状态改回未开始
    func abandon() {
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
        taskStore.setStatusWithoutUndo(reason == .abandoned ? .todo : .done, for: state.taskID)

        let wasTimeUp = phase == .timeUp
        session = nil
        phase = .idle
        timeUpAt = nil
        isImmersivePresented = false
        stopTicking()
        notifier.cancelBackup()
        // 时间到时已经关过勿扰了
        if !wasTimeUp { setDoNotDisturb(false) }
    }

    // MARK: - 计时

    /// 每秒调用；睡眠唤醒后也会立即调用一次
    func tick() {
        now = clock()
        guard phase == .running, let session, session.remaining(at: now) <= 0 else { return }
        handleTimeUp(at: session.plannedEnd)
    }

    private func handleTimeUp(at moment: Date) {
        guard let session else { return }
        phase = .timeUp
        timeUpAt = min(moment, clock())
        stopTicking()
        let title = session.taskTitle
        // 必须先关勿扰再提醒，否则提醒本身会被勿扰静音
        Task {
            await deactivateDoNotDisturb(timeout: .seconds(3))
            notifier.postTimeUp(title: title)
            NSApp?.requestUserAttention(.criticalRequest)
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
            // 防止 App Nap 拖慢计时器；不阻止系统睡眠
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

    // MARK: - 恢复

    /// App 启动时调用：恢复未结束的专注；若已超时，补上「时间到」的处理
    func restore() {
        let state: FocusSessionState?
        do {
            state = try repository.activeSession()
        } catch {
            logger.error("读取进行中的专注失败：\(error.localizedDescription, privacy: .public)")
            state = nil
        }
        guard let state else {
            // 没有进行中的专注，但勿扰还是 App 打开的（比如上次崩溃了）：关掉
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

    // MARK: - 通知动作

    func handle(_ action: FocusNotificationAction) {
        switch action {
        case .complete: phase == .timeUp ? complete() : finishEarly()
        case .extend: extend()
        }
    }

    // MARK: - 私有

    private func rescheduleBackup() {
        notifier.cancelBackup()
        guard phase == .running, let session, let end = session.expectedEnd(at: clock()) else { return }
        notifier.scheduleBackup(at: end, title: session.taskTitle)
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
                // 勿扰失败只提示，不影响计时
                dndWarning = on ? "开启勿扰失败：\(error.localizedDescription)" : "关闭勿扰失败：\(error.localizedDescription)"
                logger.error("\(self.dndWarning ?? "", privacy: .public)")
            }
        }
    }

    /// 关闭勿扰，最多等 timeout；超时就取消（快捷指令进程会被终止），不再等它
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
