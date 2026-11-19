import AppKit
import Foundation
import OSLog
// UNUserNotificationCenter is not yet marked Sendable in the macOS 14 SDK, but it is thread-safe
@preconcurrency import UserNotifications

/// Focus-related notifications
@MainActor
protocol FocusNotifying: AnyObject {
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
struct FocusProgressReminder: Equatable {
    let percent: Int
    let date: Date
    let remainingSeconds: Int
}

/// Quick actions on the notification
enum FocusNotificationAction: String {
    case complete = "COMPLETE"
    case extend = "EXTEND_15"
}

@MainActor
final class NotificationService: NSObject, FocusNotifying {
    static let categoryID = "FOCUS_END"
    private static let requestID = "focus-end"

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Notification")
    /// Silent mode (tests, screenshots): sends nothing
    private let isSilenced: Bool
    /// The user tapped a button on the notification
    var onAction: ((FocusNotificationAction) -> Void)?

    init(isSilenced: Bool = false) {
        self.isSilenced = isSilenced
        super.init()
        guard !isSilenced else { return }
        center.delegate = self
        let complete = UNNotificationAction(identifier: FocusNotificationAction.complete.rawValue,
                                            title: "标记完成", options: [])
        let extend = UNNotificationAction(identifier: FocusNotificationAction.extend.rawValue,
                                          title: "再延长 15 分钟", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [complete, extend],
                                   intentIdentifiers: [], options: [])
        ])
    }

    func requestAuthorizationIfNeeded() async {
        guard !isSilenced else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("请求通知权限失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func scheduleBackup(at date: Date, title: String) {
        let interval = date.timeIntervalSinceNow
        guard !isSilenced, interval > 1 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        add(content(title: title), trigger: trigger)
    }

    func cancelBackup() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    func scheduleProgress(_ reminders: [FocusProgressReminder], title: String) {
        guard !isSilenced else { return }
        for reminder in reminders {
            let interval = reminder.date.timeIntervalSinceNow
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "专注进度 \(reminder.percent)%"
            content.body = "「\(title)」已完成 \(reminder.percent)%，还剩 \(DurationText.minutes(reminder.remainingSeconds))"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.progressID(reminder.percent), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
            center.add(request) { [logger] error in
                if let error { logger.error("安排进度提醒失败：\(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func cancelProgress() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: (1..<100).map { Self.progressID($0) })
    }

    nonisolated private static func progressID(_ percent: Int) -> String { "focus-progress-\(percent)" }

    // MARK: - Daily review

    private static let dailyReviewID = "daily-review"

    /// Reminds about tasks still unfinished today at the given time. Same identifier, so rescheduling overwrites
    func scheduleDailyReview(at date: Date, title: String, body: String, calendar: Calendar) {
        guard !isSilenced else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: Self.dailyReviewID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        center.add(request) { [logger] error in
            if let error { logger.error("安排每日复盘失败：\(error.localizedDescription, privacy: .public)") }
        }
    }

    func cancelDailyReview() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailyReviewID])
    }

    func postTimeUp(title: String) {
        guard !isSilenced else { return }
        cancelBackup()
        add(content(title: title), trigger: nil)
        NSSound(named: "Glass")?.play()
    }

    private func content(title: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "专注时间到 🎉"
        content.body = "「\(title)」已完成计划时长，休息一下吧"
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        return content
    }

    private func add(_ content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        // Same identifier: the immediate "time is up" notification replaces the queued fallback, avoiding duplicate reminders
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: trigger)
        center.add(request) { [logger] error in
            if let error {
                logger.error("发送通知失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show the banner and play sound even when the app is in the foreground
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.actionIdentifier
        await MainActor.run {
            if let action = FocusNotificationAction(rawValue: identifier) {
                onAction?(action)
            } else {
                // tapped the notification itself: bring the app to the front
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// For tests: records calls
@MainActor
final class RecordingNotifier: FocusNotifying {
    private(set) var backups: [Date] = []
    private(set) var timeUps: [String] = []
    private(set) var cancelCount = 0
    private(set) var progress: [FocusProgressReminder] = []
    private(set) var progressCancelCount = 0

    func requestAuthorizationIfNeeded() async {}
    func scheduleBackup(at date: Date, title: String) { backups.append(date) }
    func cancelBackup() { cancelCount += 1 }
    func postTimeUp(title: String) { timeUps.append(title) }
    func scheduleProgress(_ reminders: [FocusProgressReminder], title: String) { progress = reminders }
    func cancelProgress() { progressCancelCount += 1; progress = [] }
}
