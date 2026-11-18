import AppKit
import Foundation
import Observation

/// 勿扰开关的抽象。正式实现走「快捷指令」，测试里用假实现。
@MainActor
protocol DoNotDisturbServicing: AnyObject {
    /// 用户在设置里是否打开了「专注时自动开启勿扰」
    var isEnabledInSettings: Bool { get }
    /// 勿扰当前是否是由 Immerse 打开的（用于崩溃后恢复）
    var isActivatedByApp: Bool { get }
    func activate() async throws
    func deactivate() async throws
}

/// 什么都不做的实现
@MainActor
final class NoopDoNotDisturbService: DoNotDisturbServicing {
    var isEnabledInSettings: Bool { false }
    var isActivatedByApp: Bool { false }
    func activate() async throws {}
    func deactivate() async throws {}
}

/// 用「快捷指令」切换勿扰。
///
/// macOS 没有开放切换专注模式的公共 API，所以让用户在「快捷指令」里建两个快捷指令
/// （设定专注模式 → 打开 / 关闭勿扰），App 通过 `/usr/bin/shortcuts run` 调用它们。
@MainActor
@Observable
final class ShortcutsDoNotDisturbService: DoNotDisturbServicing {
    enum SetupStatus: Equatable {
        case unknown
        case checking
        case ready
        /// 缺少的快捷指令名称
        case missing([String])
        case failed(String)
    }

    private(set) var setupStatus: SetupStatus = .unknown
    @ObservationIgnored private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var isEnabledInSettings: Bool { settings.dndEnabled }
    var isActivatedByApp: Bool { settings.dndActivatedByApp }

    func activate() async throws {
        try await ShortcutsRunner.run(settings.dndOnShortcut)
        settings.dndActivatedByApp = true
    }

    func deactivate() async throws {
        try await ShortcutsRunner.run(settings.dndOffShortcut)
        settings.dndActivatedByApp = false
    }

    /// 检查两个快捷指令是否都已经建好
    @discardableResult
    func checkSetup() async -> SetupStatus {
        setupStatus = .checking
        do {
            let names = Set(try await ShortcutsRunner.list())
            let missing = [settings.dndOnShortcut, settings.dndOffShortcut].filter { !names.contains($0) }
            setupStatus = missing.isEmpty ? .ready : .missing(missing)
        } catch {
            setupStatus = .failed(error.localizedDescription)
        }
        return setupStatus
    }

    /// 打开「快捷指令」App
    func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// 打开「系统设置 → 专注模式」，方便用户把 Immerse 加入勿扰的允许列表
    func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
