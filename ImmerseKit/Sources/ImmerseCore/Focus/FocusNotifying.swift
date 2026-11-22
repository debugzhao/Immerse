import Foundation

/// Focus-related notifications
@MainActor
public protocol FocusNotifying: AnyObject {
    func requestAuthorizationIfNeeded() async
    /// Fallback notification: if the app is killed or hangs, the system still alerts at the expected end time
    func scheduleBackup(at date: Date, title: String)
    func cancelBackup()
    /// Time is up: send a notification immediately and play a sound
    func postTimeUp(title: String)
    /// Progress reminders (e.g. halfway, 80%), delivered by the system on schedule
    func scheduleProgress(_ reminders: [FocusProgressReminder], title: String)
    func cancelProgress()
}

/// A progress reminder: fires when focus reaches percent%, with remainingSeconds left at that point
public struct FocusProgressReminder: Equatable {
    public let percent: Int
    public let date: Date
    public let remainingSeconds: Int
}

/// Quick actions on the notification
public enum FocusNotificationAction: String {
    case complete = "COMPLETE"
    case extend = "EXTEND_15"
    case close = "CLOSE"
}

/// For tests: records calls
@MainActor
public final class RecordingNotifier: FocusNotifying {
    public private(set) var backups: [Date] = []
    public private(set) var timeUps: [String] = []
    public private(set) var cancelCount = 0
    public private(set) var progress: [FocusProgressReminder] = []
    public private(set) var progressCancelCount = 0

    public init() {}

    public func requestAuthorizationIfNeeded() async {}
    public func scheduleBackup(at date: Date, title: String) { backups.append(date) }
    public func cancelBackup() { cancelCount += 1 }
    public func postTimeUp(title: String) { timeUps.append(title) }
    public func scheduleProgress(_ reminders: [FocusProgressReminder], title: String) { progress = reminders }
    public func cancelProgress() { progressCancelCount += 1; progress = [] }
}
