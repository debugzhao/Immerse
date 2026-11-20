import AppKit
import Foundation
import ImmerseCore
import Observation

/// Toggles Do Not Disturb via Shortcuts.
///
/// macOS has no public API for toggling Focus modes, so the user creates two shortcuts in the Shortcuts app
/// (set Focus → turn Do Not Disturb on / off), and the app invokes them via `/usr/bin/shortcuts run`.
@MainActor
@Observable
final class ShortcutsDoNotDisturbService: DoNotDisturbServicing {
    enum SetupStatus: Equatable {
        case unknown
        case checking
        case ready
        /// Name of the missing shortcut
        case missing([String])
        case failed(String)
        /// This Mac can't run shortcuts at all (e.g. blocked by device management)
        case blocked(String)
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

    /// Checks that both shortcuts have been created
    @discardableResult
    func checkSetup() async -> SetupStatus {
        setupStatus = .checking
        do {
            let names = Set(try await ShortcutsRunner.list())
            let missing = [settings.dndOnShortcut, settings.dndOffShortcut].filter { !names.contains($0) }
            setupStatus = missing.isEmpty ? .ready : .missing(missing)
        } catch {
            if let runError = error as? ShortcutsRunner.RunError, runError.isBlocked {
                setupStatus = .blocked(error.localizedDescription)
            } else {
                setupStatus = .failed(error.localizedDescription)
            }
        }
        return setupStatus
    }

    /// Opens the Shortcuts app
    func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Opens System Settings → Focus so the user can add Immerse to the Do Not Disturb allow list
    func openFocusSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
