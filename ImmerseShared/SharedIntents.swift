import AppIntents
import Foundation
import ImmerseCore
import WidgetKit

// Intents used by both the app and the widget extension (widget buttons, Live Activity buttons, Siri, Shortcuts).
// In the app process (`IMMERSE_APP`) they act through `AppModel` so the open store, undo history and focus engine
// stay consistent; in the widget process they write the shared App Group store directly.

/// A task as Shortcuts / Siri / widgets see it
struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "任务"
    static let defaultQuery = TaskEntityQuery()

    var id: UUID
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ task: TaskSnapshot, calendar: Calendar = .app) {
        id = task.id
        title = task.displayTitle
        subtitle = task.isAllDay ? "全天" : TimeText.hhmm(task.start, calendar: calendar)
    }
}

struct TaskEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        identifiers.compactMap { id in IntentBridge.task(id: id).map { TaskEntity($0) } }
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        IntentBridge.todayTasks().map { TaskEntity($0) }
    }
}

/// Marks a task done (widget checkbox, Shortcuts)
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "完成任务"
    static let description = IntentDescription("把今天的一个任务标记为完成")

    @Parameter(title: "任务") var task: TaskEntity

    init() {}
    init(task: TaskEntity) { self.task = task }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.complete(task.id)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// Starts focusing on a task; opens the app, where the countdown and Live Activity live
struct StartFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "开始专注"
    static let description = IntentDescription("打开沉浸日程并开始专注一个任务。可以和「设定专注模式」放进同一个快捷指令，一起开启勿扰")
    static let openAppWhenRun = true

    @Parameter(title: "任务") var task: TaskEntity?

    init() {}
    init(task: TaskEntity) { self.task = task }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.startFocus(task?.id)
        return .result()
    }
}

/// Pause / resume from the Live Activity (runs in the app process)
struct ToggleFocusPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暂停或继续专注"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.togglePause()
        return .result()
    }
}

/// Finish the session from the Live Activity
struct FinishFocusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "完成专注"

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.finishFocus()
        return .result()
    }
}

/// Where an intent's work happens, depending on the process it runs in
@MainActor
enum IntentBridge {
    static func todayTasks() -> [TaskSnapshot] {
        #if IMMERSE_APP
        if let model = AppModel.shared {
            let calendar = model.schedule.calendar
            let start = calendar.startOfDay(for: .now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return model.taskStore.tasks(in: DateInterval(start: start, end: end)).filter { $0.status != .done }
        }
        #endif
        return SharedStore.todayTasks()
    }

    static func task(id: UUID) -> TaskSnapshot? {
        #if IMMERSE_APP
        if let model = AppModel.shared { return model.taskStore.task(id: id) }
        #endif
        return SharedStore.task(id: id)
    }

    static func complete(_ id: UUID) {
        #if IMMERSE_APP
        if let model = AppModel.shared {
            model.taskStore.setStatus(.done, for: id)
            return
        }
        #endif
        SharedStore.setDone(id)
    }

    static func startFocus(_ id: UUID?) {
        #if IMMERSE_APP
        guard let model = AppModel.shared else { return }
        model.taskStore.reloadFromStore()
        model.schedule.selectedTab = .focus
        if let id, let task = model.taskStore.task(id: id) {
            model.focusEngine.requestStart(task)
        }
        #endif
    }

    static func togglePause() {
        #if IMMERSE_APP
        AppModel.shared?.focusEngine.togglePause()
        #endif
    }

    static func finishFocus() {
        #if IMMERSE_APP
        guard let engine = AppModel.shared?.focusEngine else { return }
        if engine.phase == .timeUp { engine.complete() } else { engine.finishEarly() }
        #endif
    }
}
