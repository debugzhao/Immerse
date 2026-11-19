import Foundation
import Observation
import OSLog

/// Starts a countdown in the system Clock app when focus begins.
///
/// Clock has no API for third-party apps, so this goes through Shortcuts: the user creates a shortcut
/// (takes numeric input → Clock "Start Timer"), and the app passes the focus minutes to it as input.
@MainActor
@Observable
final class ClockTimerService {
    enum SetupStatus: Equatable {
        case unknown
        case checking
        case ready
        case missing
        case failed(String)
    }

    private(set) var setupStatus: SetupStatus = .unknown
    /// Reason the most recent countdown start failed
    private(set) var lastError: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "ClockTimer")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Called when focus starts; does nothing if turned off in settings
    func startIfEnabled(minutes: Int) {
        guard settings.clockTimerEnabled else { return }
        Task { await start(minutes: minutes) }
    }

    @discardableResult
    func start(minutes: Int) async -> Bool {
        do {
            try await ShortcutsRunner.run(settings.clockTimerShortcut, input: "\(minutes)", timeout: .seconds(10))
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            logger.error("开倒计时失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func checkSetup() async {
        setupStatus = .checking
        do {
            let names = try await ShortcutsRunner.list()
            setupStatus = names.contains(settings.clockTimerShortcut) ? .ready : .missing
        } catch {
            setupStatus = .failed(error.localizedDescription)
        }
    }
}
