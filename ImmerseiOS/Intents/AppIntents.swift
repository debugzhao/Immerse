import AppIntents
import Foundation
import ImmerseAgent
import ImmerseCore

/// 「嘿 Siri，用沉浸日程记一下」: captures a sentence into the Inbox without opening the app.
/// Parsed with the rule parser; the AI can refine it later from the app.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "记一下"
    static let description = IntentDescription("把一句话记进沉浸日程。有时间的会放进日程，没有时间的放进收集箱")

    @Parameter(title: "内容", requestValueDialog: "要记什么？") var text: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else { return .result(dialog: "沉浸日程还没准备好，请稍后再试") }
        let calendar = model.schedule.calendar
        let draft = StructuredCalls.ruleCapture(text, now: .now, calendar: calendar)
        if draft.kind == .goal {
            _ = model.taskStore.createGoal(draft.title, period: draft.goalPeriod ?? .week, calendar: calendar)
            return .result(dialog: "已创建目标：\(draft.title)")
        }
        let task = model.taskStore.create(draft.snapshot(fallbackStart: .now, source: .siri, calendar: calendar), actionName: "收集")
        if task.kind == .event {
            return .result(dialog: "已添加到\(TimeText.weekday(task.start, calendar: calendar)) \(TimeText.hhmm(task.start, calendar: calendar))：\(task.displayTitle)")
        }
        return .result(dialog: "已放进收集箱：\(task.displayTitle)")
    }
}

/// Opens the app with the secretary's plan for this week's Inbox
struct PlanWeekIntent: AppIntent {
    static let title: LocalizedStringResource = "把收集箱排进本周"
    static let description = IntentDescription("让秘书把收集箱里的想法排进本周的空档，打开 App 确认后才会写入")
    static let openAppWhenRun = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else { return .result() }
        if let proposal = await model.secretary.planInbox() {
            model.schedule.showProposal(proposal, secretary: model.secretary)
        }
        return .result()
    }
}

/// Phrases Siri recognizes without setup; also what the Action Button and Shortcuts app list first
struct ImmerseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(), phrases: [
            "用\(.applicationName)记一下",
            "在\(.applicationName)里记一下",
            "\(.applicationName)记一下",
        ], shortTitle: "记一下", systemImageName: "square.and.pencil")
        AppShortcut(intent: StartFocusIntent(), phrases: [
            "用\(.applicationName)开始专注",
            "\(.applicationName)开始专注",
        ], shortTitle: "开始专注", systemImageName: "timer")
        AppShortcut(intent: PlanWeekIntent(), phrases: [
            "用\(.applicationName)排一下本周",
            "\(.applicationName)帮我排一下本周",
        ], shortTitle: "排进本周", systemImageName: "sparkles")
    }
}

/// Focus Filter: while a system Focus mode with this filter is on, the secretary holds its proactive notifications.
/// The system calls `perform` with the configured values when the Focus starts and with defaults when it ends.
struct ImmerseFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "沉浸日程"
    static let description: IntentDescription? = "专注模式开启时，秘书暂停晨间简报和预警提醒"

    @Parameter(title: "暂停秘书提醒", default: false) var holdNudges: Bool

    init() {}

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: holdNudges ? "暂停秘书提醒" : "照常提醒")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared else {
            UserDefaults.standard.set(holdNudges, forKey: "secretary.systemFocusQuiet")
            return .result()
        }
        model.preferences.isSystemFocusQuiet = holdNudges
        model.nudges.refresh()
        return .result()
    }
}
