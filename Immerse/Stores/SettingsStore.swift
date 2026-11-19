import Foundation
import Observation

/// 用户设置，存在 UserDefaults
@MainActor
@Observable
final class SettingsStore {
    enum Key {
        static let dndEnabled = "dnd.enabled"
        static let dndOnShortcut = "dnd.onShortcut"
        static let dndOffShortcut = "dnd.offShortcut"
        static let dndActivatedByApp = "dnd.activatedByApp"
        static let onboardingCompleted = "onboarding.completed"
        static let progressMilestones = "notify.progressMilestones"
        static let dailyReviewEnabled = "notify.dailyReview.enabled"
        static let dailyReviewMinutes = "notify.dailyReview.minutes"
        static let clockTimerEnabled = "clockTimer.enabled"
        static let clockTimerShortcut = "clockTimer.shortcut"
    }

    static let defaultClockTimerShortcut = "Immerse 开始计时"
    /// 进度提醒可选的百分比
    static let milestoneOptions = [25, 50, 75, 80, 90]

    static let defaultOnShortcut = "Immerse 开启勿扰"
    static let defaultOffShortcut = "Immerse 关闭勿扰"

    @ObservationIgnored private let defaults: UserDefaults

    /// 专注时自动开启勿扰
    var dndEnabled: Bool { didSet { defaults.set(dndEnabled, forKey: Key.dndEnabled) } }
    var dndOnShortcut: String { didSet { defaults.set(dndOnShortcut, forKey: Key.dndOnShortcut) } }
    var dndOffShortcut: String { didSet { defaults.set(dndOffShortcut, forKey: Key.dndOffShortcut) } }
    /// 勿扰是由 Immerse 打开的：崩溃后重启时据此关闭勿扰
    var dndActivatedByApp: Bool { didSet { defaults.set(dndActivatedByApp, forKey: Key.dndActivatedByApp) } }
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }

    /// 专注到这些百分比时发进度提醒（默认 50%、80%）
    var progressMilestones: [Int] { didSet { defaults.set(progressMilestones, forKey: Key.progressMilestones) } }
    /// 每天定时提醒还没完成的任务
    var dailyReviewEnabled: Bool { didSet { defaults.set(dailyReviewEnabled, forKey: Key.dailyReviewEnabled) } }
    /// 每日复盘提醒时间：当天 0 点起的分钟数（默认 21:00）
    var dailyReviewMinutes: Int { didSet { defaults.set(dailyReviewMinutes, forKey: Key.dailyReviewMinutes) } }
    /// 开始专注时用快捷指令在「时钟」里开倒计时
    var clockTimerEnabled: Bool { didSet { defaults.set(clockTimerEnabled, forKey: Key.clockTimerEnabled) } }
    var clockTimerShortcut: String { didSet { defaults.set(clockTimerShortcut, forKey: Key.clockTimerShortcut) } }

    func toggleMilestone(_ percent: Int) {
        if progressMilestones.contains(percent) {
            progressMilestones.removeAll { $0 == percent }
        } else {
            progressMilestones = (progressMilestones + [percent]).sorted()
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.dndEnabled: true,
            Key.dndOnShortcut: Self.defaultOnShortcut,
            Key.dndOffShortcut: Self.defaultOffShortcut,
            Key.progressMilestones: [50, 80],
            Key.dailyReviewEnabled: true,
            Key.dailyReviewMinutes: 21 * 60,
            Key.clockTimerEnabled: true,
            Key.clockTimerShortcut: Self.defaultClockTimerShortcut,
        ])
        dndEnabled = defaults.bool(forKey: Key.dndEnabled)
        dndOnShortcut = defaults.string(forKey: Key.dndOnShortcut) ?? Self.defaultOnShortcut
        dndOffShortcut = defaults.string(forKey: Key.dndOffShortcut) ?? Self.defaultOffShortcut
        dndActivatedByApp = defaults.bool(forKey: Key.dndActivatedByApp)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        progressMilestones = (defaults.array(forKey: Key.progressMilestones) as? [Int]) ?? [50, 80]
        dailyReviewEnabled = defaults.bool(forKey: Key.dailyReviewEnabled)
        dailyReviewMinutes = defaults.integer(forKey: Key.dailyReviewMinutes)
        clockTimerEnabled = defaults.bool(forKey: Key.clockTimerEnabled)
        clockTimerShortcut = defaults.string(forKey: Key.clockTimerShortcut) ?? Self.defaultClockTimerShortcut
    }
}
