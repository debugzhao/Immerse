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
    }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.dndEnabled: true,
            Key.dndOnShortcut: Self.defaultOnShortcut,
            Key.dndOffShortcut: Self.defaultOffShortcut,
        ])
        dndEnabled = defaults.bool(forKey: Key.dndEnabled)
        dndOnShortcut = defaults.string(forKey: Key.dndOnShortcut) ?? Self.defaultOnShortcut
        dndOffShortcut = defaults.string(forKey: Key.dndOffShortcut) ?? Self.defaultOffShortcut
        dndActivatedByApp = defaults.bool(forKey: Key.dndActivatedByApp)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
    }
}
