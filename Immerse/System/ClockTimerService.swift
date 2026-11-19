import Foundation
import Observation
import OSLog

/// 开始专注时在系统「时钟」里开一个倒计时。
///
/// 「时钟」没有开放给第三方 App 的 API，所以借助快捷指令：用户建一个快捷指令
/// （接收数字输入 → 时钟「开始计时器」），App 把专注分钟数作为输入传给它。
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
    /// 最近一次开倒计时失败的原因
    private(set) var lastError: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "ClockTimer")

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// 专注开始时调用；设置里关掉了就什么都不做
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
