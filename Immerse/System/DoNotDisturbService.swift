import Foundation

/// 勿扰开关的抽象。M4 用「快捷指令」实现，测试里用假实现。
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
