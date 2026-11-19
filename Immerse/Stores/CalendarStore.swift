import Foundation
import Observation

enum CalendarMode: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    /// 0 = finest (day), 2 = coarsest (month)
    var zoomLevel: Int {
        switch self {
        case .day: 0
        case .week: 1
        case .month: 2
        }
    }

    var title: String {
        switch self {
        case .day: "日"
        case .week: "周"
        case .month: "月"
        }
    }
}

extension Calendar {
    /// The calendar used app-wide: Gregorian, Chinese locale, weeks start on Monday.
    static let app: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()
}

struct ScrollRequest: Equatable {
    var hour: Int
    var token = UUID()
}

/// A new event created by drag-selecting, not yet named
struct DraftEvent: Equatable {
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    /// Default time from ⌘N (not picked by the user on the calendar): restored together with the unsaved content
    var usesDefaultTime = false
}

/// Calendar browsing state: which day, which view, which task is selected, and the filters.
@MainActor
@Observable
final class CalendarStore {
    var anchorDate: Date
    var mode: CalendarMode = .week {
        didSet { if mode != oldValue { previousMode = oldValue } }
    }
    /// Mode before the last switch, used to pick the zoom direction of the transition
    private(set) var previousMode: CalendarMode = .week
    /// Top hour of the time grid when it was last scrolled, so switching day ↔ week keeps the position
    @ObservationIgnored var lastScrollHour: Int?
    var selectedTaskID: UUID?
    let calendar: Calendar

    // Filters and search
    var priorityFilter: Set<Priority> = Set(Priority.allCases)
    var statusFilter: Set<TaskStatus> = Set(TaskStatus.allCases)
    var searchText = ""

    /// Draft being created by dragging
    var draft: DraftEvent? { didSet { if draft != nil { hoveredTaskID = nil } } }
    /// Task being dragged; raises its column to the top so it is not covered when dragged over an adjacent column
    var draggingTaskID: UUID? { didSet { if draggingTaskID != nil { hoveredTaskID = nil } } }
    /// Event under the mouse (shows the "专注" (Focus) quick button). Global singleton so multiple blocks cannot show it at once if an exit event is lost
    var hoveredTaskID: UUID?
    /// Content left over when the create sheet is closed without saving; restored the next time it opens
    var unsavedDraft: TaskSnapshot?
    /// Task being edited in the event sheet
    var editingTaskID: UUID? { didSet { if editingTaskID != nil { hoveredTaskID = nil } } }
    /// While the create sheet is open, ⌘↩ in the menu becomes "Create"
    @ObservationIgnored var submitDraft: (() -> Void)?
    /// Request to focus the search field (⌘F)
    var wantsSearchFocus = false
    /// Whether the command palette is open
    var isCommandPalettePresented = false
    /// Reopened from Help → 重新查看引导
    var isOnboardingPresented = false
    /// Time grid scroll request: each newly assigned value triggers one scroll
    var scrollRequest = ScrollRequest(hour: 8) {
        // An explicit scroll request (reveal, ⌘N) wins over the remembered position
        didSet { lastScrollHour = nil }
    }
    /// Notion import awaiting confirmation
    var pendingImport: ImportPreview?

    init(anchorDate: Date = .now, calendar: Calendar = .app) {
        self.anchorDate = anchorDate
        self.calendar = calendar
    }

    var visibleInterval: DateInterval {
        let component: Calendar.Component = switch mode {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        return calendar.dateInterval(of: component, for: anchorDate)
            ?? DateInterval(start: calendar.startOfDay(for: anchorDate), duration: 24 * 3600)
    }

    /// Dates the time grid displays (each element is midnight of that day).
    var visibleDays: [Date] {
        days(in: visibleInterval)
    }

    func days(in interval: DateInterval) -> [Date] {
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// Top bar title, e.g. "2026年11月"; a week spanning two months shows "2026年11月 – 12月", and day view shows "2026年11月18日".
    var title: String {
        if mode == .day {
            let c = calendar.dateComponents([.year, .month, .day], from: anchorDate)
            return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
        }
        let interval = visibleInterval
        let last = interval.end.addingTimeInterval(-1)
        let (y1, m1) = (calendar.component(.year, from: interval.start), calendar.component(.month, from: interval.start))
        let (y2, m2) = (calendar.component(.year, from: last), calendar.component(.month, from: last))
        if y1 == y2 && m1 == m2 { return "\(y1)年\(m1)月" }
        if y1 == y2 { return "\(y1)年\(m1)月 – \(m2)月" }
        return "\(y1)年\(m1)月 – \(y2)年\(m2)月"
    }

    /// ISO week number, used for the small label next to the title
    var weekNumber: Int {
        calendar.component(.weekOfYear, from: anchorDate)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func goToToday() {
        anchorDate = .now
    }

    /// direction: -1 for the previous page, +1 for the next
    func step(_ direction: Int) {
        let (component, value): (Calendar.Component, Int) = switch mode {
        case .day: (.day, direction)
        case .week: (.day, 7 * direction)
        case .month: (.month, direction)
        }
        anchorDate = calendar.date(byAdding: component, value: value, to: anchorDate) ?? anchorDate
    }

    func select(_ id: UUID?) {
        selectedTaskID = id
        if id != nil { draft = nil }
        if id != editingTaskID { editingTaskID = nil }
    }

    /// Whether the create or edit sheet is open
    var isEditorPresented: Bool {
        draft != nil || editingTaskID != nil
    }

    /// Open the event sheet for editing
    func openEditor(_ id: UUID) {
        select(id)
        editingTaskID = id
    }

    /// Search result picked: events jump to their date, Inbox ideas and goals open in the editor
    func show(_ task: TaskSnapshot) {
        if task.kind == .event {
            reveal(task)
        } else {
            openEditor(task.id)
        }
    }

    /// Jump to the date of a task and select it
    func reveal(_ task: TaskSnapshot) {
        anchorDate = task.start
        if mode == .month { mode = .week }
        select(task.id)
        if !task.isAllDay {
            // Scroll to one hour before the event starts so it appears in the upper part of the viewport
            scrollRequest = ScrollRequest(hour: max(calendar.component(.hour, from: task.start) - 1, 0))
        }
    }

    // MARK: - Filters

    var isFiltering: Bool {
        priorityFilter.count < Priority.allCases.count || statusFilter.count < TaskStatus.allCases.count
    }

    func passesFilter(_ task: TaskSnapshot) -> Bool {
        priorityFilter.contains(task.priority) && statusFilter.contains(task.status)
    }

    func toggle(_ priority: Priority) {
        if priorityFilter.contains(priority) { priorityFilter.remove(priority) } else { priorityFilter.insert(priority) }
    }

    func toggle(_ status: TaskStatus) {
        if statusFilter.contains(status) { statusFilter.remove(status) } else { statusFilter.insert(status) }
    }

    func resetFilters() {
        priorityFilter = Set(Priority.allCases)
        statusFilter = Set(TaskStatus.allCases)
    }

    // MARK: - Create

    /// Initial content when opening the create sheet: restores unsaved content from last time, if any.
    /// The time is whatever was just picked on the calendar; with ⌘N (default time), last time's time is restored too.
    func makeNewTask(for draft: DraftEvent) -> (task: TaskSnapshot, isRestored: Bool) {
        let fresh = TaskSnapshot(title: "", start: draft.start, end: draft.isAllDay ? nil : draft.end, isAllDay: draft.isAllDay)
        guard var saved = unsavedDraft else { return (fresh, false) }
        if !draft.usesDefaultTime {
            saved.start = fresh.start
            saved.end = fresh.end
            saved.isAllDay = fresh.isAllDay
        }
        return (saved, true)
    }

    /// Create sheet closed without creating: keep anything filled in for the next restore; discard it if nothing was filled in
    func keepUnsaved(_ task: TaskSnapshot) {
        unsavedDraft = task.hasUserContent ? task : nil
    }

    /// Default time for ⌘N: when viewing today, the next full hour, otherwise 9:00 on that day; duration 1 hour
    func defaultNewEventInterval(now: Date = .now) -> DateInterval {
        let base: Date
        if calendar.isDate(anchorDate, inSameDayAs: now) {
            let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            base = nextHour
        } else {
            base = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: anchorDate) ?? anchorDate
        }
        return DateInterval(start: base, duration: 3600)
    }
}

extension TaskSnapshot {
    /// Whether the user filled in anything in the create form (time does not count; it comes from the calendar selection)
    var hasUserContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(place ?? "").isEmpty
            || priority != .normal
            || status != .todo
            || plannedMinutes != nil
    }
}
