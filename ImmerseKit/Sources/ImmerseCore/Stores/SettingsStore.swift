import Foundation
import Observation

/// User settings, stored in UserDefaults
@MainActor
@Observable
public final class SettingsStore {
    public enum Key {
        public static let dndEnabled = "dnd.enabled"
        public static let dndOnShortcut = "dnd.onShortcut"
        public static let dndOffShortcut = "dnd.offShortcut"
        public static let dndActivatedByApp = "dnd.activatedByApp"
        public static let onboardingCompleted = "onboarding.completed"
        public static let progressMilestones = "notify.progressMilestones"
        public static let dailyReviewEnabled = "notify.dailyReview.enabled"
        public static let dailyReviewMinutes = "notify.dailyReview.minutes"
        public static let clockTimerEnabled = "clockTimer.enabled"
        public static let clockTimerShortcut = "clockTimer.shortcut"
        public static let autoFocusEnabled = "autoFocus.enabled"
        public static let dailyPlanEnabled = "dailyPlan.enabled"
        public static let dailyPlanLastShown = "dailyPlan.lastShown"
    }

    public static let defaultClockTimerShortcut = "Immerse 开始计时"
    /// Selectable percentages for progress reminders
    public static let milestoneOptions = [25, 50, 75, 80, 90]

    public static let defaultOnShortcut = "Immerse 开启勿扰"
    public static let defaultOffShortcut = "Immerse 关闭勿扰"

    @ObservationIgnored private let defaults: UserDefaults

    /// Auto-enable Do Not Disturb during focus
    public var dndEnabled: Bool { didSet { defaults.set(dndEnabled, forKey: Key.dndEnabled) } }
    public var dndOnShortcut: String { didSet { defaults.set(dndOnShortcut, forKey: Key.dndOnShortcut) } }
    public var dndOffShortcut: String { didSet { defaults.set(dndOffShortcut, forKey: Key.dndOffShortcut) } }
    /// Do Not Disturb was turned on by Immerse: used to turn it off on relaunch after a crash
    public var dndActivatedByApp: Bool { didSet { defaults.set(dndActivatedByApp, forKey: Key.dndActivatedByApp) } }
    public var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }

    /// Send progress reminders when focus reaches these percentages (default 50%, 80%)
    public var progressMilestones: [Int] { didSet { defaults.set(progressMilestones, forKey: Key.progressMilestones) } }
    /// Daily reminder for tasks not yet completed
    public var dailyReviewEnabled: Bool { didSet { defaults.set(dailyReviewEnabled, forKey: Key.dailyReviewEnabled) } }
    /// Daily review reminder time: minutes since midnight (default 21:00)
    public var dailyReviewMinutes: Int { didSet { defaults.set(dailyReviewMinutes, forKey: Key.dailyReviewMinutes) } }
    /// Use a shortcut to start a countdown in Clock when focus begins
    public var clockTimerEnabled: Bool { didSet { defaults.set(clockTimerEnabled, forKey: Key.clockTimerEnabled) } }
    public var clockTimerShortcut: String { didSet { defaults.set(clockTimerShortcut, forKey: Key.clockTimerShortcut) } }
    /// Start focusing automatically when a timed event begins
    public var autoFocusEnabled: Bool { didSet { defaults.set(autoFocusEnabled, forKey: Key.autoFocusEnabled) } }
    /// Pop up "今日规划" the first time the app is opened each day
    public var dailyPlanEnabled: Bool { didSet { defaults.set(dailyPlanEnabled, forKey: Key.dailyPlanEnabled) } }
    /// When "今日规划" was last shown, so it only appears once a day
    public var dailyPlanLastShown: Date? { didSet { defaults.set(dailyPlanLastShown, forKey: Key.dailyPlanLastShown) } }

    public func toggleMilestone(_ percent: Int) {
        if progressMilestones.contains(percent) {
            progressMilestones.removeAll { $0 == percent }
        } else {
            progressMilestones = (progressMilestones + [percent]).sorted()
        }
    }
    public init(defaults: UserDefaults = .standard) {
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
            Key.autoFocusEnabled: true,
            Key.dailyPlanEnabled: true,
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
        autoFocusEnabled = defaults.bool(forKey: Key.autoFocusEnabled)
        dailyPlanEnabled = defaults.bool(forKey: Key.dailyPlanEnabled)
        dailyPlanLastShown = defaults.object(forKey: Key.dailyPlanLastShown) as? Date
    }
}
