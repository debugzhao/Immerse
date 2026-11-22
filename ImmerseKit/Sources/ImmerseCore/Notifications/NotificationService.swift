import Foundation
import OSLog
// UNUserNotificationCenter is not yet marked Sendable in the macOS 14 SDK, but it is thread-safe
@preconcurrency import UserNotifications

@MainActor
@Observable
public final class NotificationService: NSObject, FocusNotifying, AutoFocusNotifying {
    public enum Permission: Equatable {
        case unknown
        case notDetermined
        case authorized
        case denied
    }

    /// Current notification permission, refreshed by `refreshPermission()`
    public private(set) var permission: Permission = .unknown

    public static let categoryID = "FOCUS_END"
    private static let requestID = "focus-end"

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.debugzhao.immerse", category: "Notification")
    /// Silent mode (tests, screenshots): sends nothing
    private let isSilenced: Bool
    /// The user tapped a button on the notification
    @ObservationIgnored public var onAction: ((FocusNotificationAction) -> Void)?
    /// The user tapped a button on an auto-focus notification (the UUID is the event's)
    @ObservationIgnored public var onAutoFocusAction: ((AutoFocusAction, UUID) -> Void)?
    /// The daily review notification was tapped
    @ObservationIgnored public var onDailyReviewOpened: (() -> Void)?
    /// A secretary nudge (morning briefing, risk alert…) was tapped; the argument is its identifier
    @ObservationIgnored public var onNudgeOpened: ((String) -> Void)?
    /// A notification itself (not one of its buttons) was tapped: the platform brings the app forward (macOS)
    @ObservationIgnored public var onNotificationOpened: (() -> Void)?
    /// macOS keeps running and starts a due event by itself; iOS is suspended, so its notification asks for a tap
    @ObservationIgnored public var startsDueEventsByItself = true
    /// Extra sound when time is up while the app is running (macOS plays "Glass"; iOS relies on the notification sound)
    @ObservationIgnored public var playTimeUpSound: (() -> Void)?

    public static let upcomingCategoryID = "AUTO_FOCUS_UPCOMING"
    public static let autoStartedCategoryID = "AUTO_FOCUS_STARTED"
    public static let conflictCategoryID = "AUTO_FOCUS_CONFLICT"
    private static let upcomingID = "auto-focus-upcoming"
    private static let autoStartedID = "auto-focus-started"
    private static let conflictID = "auto-focus-conflict"
    public nonisolated static let taskIDKey = "taskID"

    public init(isSilenced: Bool = false) {
        self.isSilenced = isSilenced
        super.init()
        guard !isSilenced else { return }
        center.delegate = self
        let complete = UNNotificationAction(identifier: FocusNotificationAction.complete.rawValue,
                                            title: "标记完成", options: [])
        let extend = UNNotificationAction(identifier: FocusNotificationAction.extend.rawValue,
                                          title: "再延长 15 分钟", options: [])
        let close = UNNotificationAction(identifier: FocusNotificationAction.close.rawValue,
                                         title: "关闭", options: [])
        let snooze = UNNotificationAction(identifier: AutoFocusAction.snooze.rawValue, title: "推迟 5 分钟", options: [])
        let skip = UNNotificationAction(identifier: AutoFocusAction.skip.rawValue, title: "跳过", options: [])
        let abandon = UNNotificationAction(identifier: AutoFocusAction.abandon.rawValue, title: "放弃本次", options: [])
        let switchFocus = UNNotificationAction(identifier: AutoFocusAction.switchFocus.rawValue, title: "切换到这个日程", options: [])
        let startNow = UNNotificationAction(identifier: AutoFocusAction.startNow.rawValue, title: "开始专注", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [complete, extend, close],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.upcomingCategoryID, actions: [startNow, snooze, skip],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.autoStartedCategoryID, actions: [abandon],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.conflictCategoryID, actions: [switchFocus],
                                   intentIdentifiers: [], options: []),
        ])
    }

    // MARK: - Permission

    public func refreshPermission() async {
        guard !isSilenced else {
            // Screenshots: show the not-yet-asked state so the onboarding step is visible
            permission = .notDetermined
            return
        }
        permission = switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    /// Ask for permission (only shows the system prompt the first time), then refresh
    public func requestPermission() async {
        await requestAuthorizationIfNeeded()
        await refreshPermission()
    }

    public func requestAuthorizationIfNeeded() async {
        guard !isSilenced else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("请求通知权限失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    public func scheduleBackup(at date: Date, title: String) {
        let interval = date.timeIntervalSinceNow
        guard !isSilenced, interval > 1 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        add(content(title: title), trigger: trigger)
    }

    public func cancelBackup() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    public func scheduleProgress(_ reminders: [FocusProgressReminder], title: String) {
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

    public func cancelProgress() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: (1..<100).map { Self.progressID($0) })
    }

    nonisolated private static func progressID(_ percent: Int) -> String { "focus-progress-\(percent)" }

    // MARK: - Daily review

    nonisolated private static let dailyReviewID = "daily-review"

    /// Reminds about tasks still unfinished today at the given time. Same identifier, so rescheduling overwrites
    public func scheduleDailyReview(at date: Date, title: String, body: String, calendar: Calendar) {
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

    public func cancelDailyReview() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.dailyReviewID])
    }

    // MARK: - Secretary nudges

    public nonisolated static let nudgePrefix = "nudge."

    /// A one-off proactive notification (morning briefing, deadline alert…). Same identifier replaces the queued one.
    /// - Parameter isPassive: delivered quietly to Notification Center, without sound or lighting the screen
    public func scheduleNudge(id: String, at date: Date, title: String, body: String, isPassive: Bool, calendar: Calendar) {
        guard !isSilenced, date > Date.now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isPassive ? nil : .default
        content.interruptionLevel = isPassive ? .passive : .active
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: Self.nudgePrefix + id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        center.add(request) { [logger] error in
            if let error { logger.error("安排秘书提醒失败：\(error.localizedDescription, privacy: .public)") }
        }
    }

    public func cancelNudges(ids: [String]) {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids.map { Self.nudgePrefix + $0 })
    }

    // MARK: - Auto focus

    public func scheduleAutoFocusUpcoming(taskID: UUID, title: String, start: Date, at date: Date) {
        let interval = date.timeIntervalSinceNow
        guard !isSilenced, interval > 1 else { return }
        let lead = max(Int((start.timeIntervalSince(date) / 60).rounded()), 1)
        let content = UNMutableNotificationContent()
        content.title = "「\(title)」\(lead) 分钟后开始"
        content.body = startsDueEventsByItself
            ? "\(TimeText.hhmm(start)) 到点会自动开始专注，任务转为进行中"
            : "\(TimeText.hhmm(start)) 开始，点「开始专注」进入倒计时"
        content.sound = .default
        content.categoryIdentifier = Self.upcomingCategoryID
        content.userInfo = [Self.taskIDKey: taskID.uuidString]
        // Same identifier: a newer schedule replaces the queued one
        let request = UNNotificationRequest(
            identifier: Self.upcomingID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        center.add(request) { [logger] error in
            if let error { logger.error("安排开始提醒失败：\(error.localizedDescription, privacy: .public)") }
        }
    }

    public func cancelAutoFocusUpcoming() {
        guard !isSilenced else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.upcomingID])
    }

    public func postAutoFocusStarted(taskID: UUID, title: String, plannedSeconds: Int) {
        guard !isSilenced else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.upcomingID])
        let content = UNMutableNotificationContent()
        content.title = "已开始专注「\(title)」"
        content.body = "日程到点，自动开始专注 \(DurationText.minutes(plannedSeconds))，任务已转为进行中"
        content.sound = .default
        content.categoryIdentifier = Self.autoStartedCategoryID
        content.userInfo = [Self.taskIDKey: taskID.uuidString]
        postNow(content, identifier: Self.autoStartedID)
    }

    public func postAutoFocusConflict(taskID: UUID, title: String, currentTitle: String) {
        guard !isSilenced else { return }
        center.removeDeliveredNotifications(withIdentifiers: [Self.upcomingID])
        let content = UNMutableNotificationContent()
        content.title = "「\(title)」已到开始时间"
        content.body = "正在专注「\(currentTitle)」，没有打断。要切换到这个日程吗？"
        content.sound = .default
        content.categoryIdentifier = Self.conflictCategoryID
        content.userInfo = [Self.taskIDKey: taskID.uuidString]
        postNow(content, identifier: Self.conflictID)
    }

    private func postNow(_ content: UNNotificationContent, identifier: String) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { [logger] error in
            if let error { logger.error("发送通知失败：\(error.localizedDescription, privacy: .public)") }
        }
    }

    public func postTimeUp(title: String) {
        guard !isSilenced else { return }
        cancelBackup()
        add(content(title: title), trigger: nil)
        playTimeUpSound?()
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
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.actionIdentifier
        let taskID = (response.notification.request.content.userInfo[Self.taskIDKey] as? String).flatMap(UUID.init)
        let requestID = response.notification.request.identifier
        let isDailyReview = requestID == Self.dailyReviewID
        let nudgeID = requestID.hasPrefix(Self.nudgePrefix) ? String(requestID.dropFirst(Self.nudgePrefix.count)) : nil
        await MainActor.run {
            if let action = AutoFocusAction(rawValue: identifier), let taskID {
                onAutoFocusAction?(action, taskID)
            } else if let action = FocusNotificationAction(rawValue: identifier) {
                onAction?(action)
            } else {
                // tapped the notification itself: bring the app to the front
                onNotificationOpened?()
                if isDailyReview { onDailyReviewOpened?() }
                if let nudgeID { onNudgeOpened?(nudgeID) }
            }
        }
    }
}

