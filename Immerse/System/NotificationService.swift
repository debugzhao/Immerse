import AppKit
import Foundation
import OSLog
// UNUserNotificationCenter 在 macOS 14 SDK 里还没标 Sendable，但它本身是线程安全的
@preconcurrency import UserNotifications

/// 专注相关的通知
@MainActor
protocol FocusNotifying: AnyObject {
    func requestAuthorizationIfNeeded() async
    /// 兜底通知：App 被杀掉或卡住时，系统仍会在预计结束时间提醒
    func scheduleBackup(at date: Date, title: String)
    func cancelBackup()
    /// 时间到：立即发通知并播放提示音
    func postTimeUp(title: String)
    /// 进度提醒（比如过半、80%），由系统按时发出
    func scheduleProgress(_ reminders: [FocusProgressReminder], title: String)
    func cancelProgress()
}

/// 一条进度提醒：专注到 percent% 时提醒，届时还剩 remainingSeconds
struct FocusProgressReminder: Equatable {
    let percent: Int
    let date: Date
    let remainingSeconds: Int
}

/// 通知上的快捷操作
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
    /// 静默模式（测试、截图）：什么都不发
    private let isSilenced: Bool
    /// 用户点了通知上的按钮
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

    // MARK: - 每日复盘

    private static let dailyReviewID = "daily-review"

    /// 在指定时刻提醒今天还没完成的任务。同一个 identifier，重复安排会覆盖
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
        // 同一个 identifier：立即发的「时间到」会替换掉排队中的兜底通知，不会重复提醒
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: trigger)
        center.add(request) { [logger] error in
            if let error {
                logger.error("发送通知失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// App 在前台时也显示横幅、播放声音
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
                // 点了通知本身：把 App 叫到前台
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// 测试用：记录调用
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
