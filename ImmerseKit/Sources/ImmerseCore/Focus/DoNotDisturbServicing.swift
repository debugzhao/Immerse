import Foundation

/// Abstraction over the Do Not Disturb switch. The real implementation goes through Shortcuts; tests use a fake.
@MainActor
public protocol DoNotDisturbServicing: AnyObject {
    /// Whether the user enabled "auto-enable Do Not Disturb during focus" in settings
    var isEnabledInSettings: Bool { get }
    /// Whether Do Not Disturb is currently on because of Immerse (used for recovery after a crash)
    var isActivatedByApp: Bool { get }
    func activate() async throws
    func deactivate() async throws
}

/// Implementation that does nothing
@MainActor
public final class NoopDoNotDisturbService: DoNotDisturbServicing {
    public init() {}
    public var isEnabledInSettings: Bool { false }
    public var isActivatedByApp: Bool { false }
    public func activate() async throws {}
    public func deactivate() async throws {}
}
