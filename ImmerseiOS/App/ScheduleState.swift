import Foundation
import ImmerseAgent
import ImmerseCore
import Observation
import UIKit

/// Calendar modes on iPhone: one day, three days (fits a phone's width), and a month overview
enum ScheduleMode: String, CaseIterable, Identifiable {
    case day
    case threeDay
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "日"
        case .threeDay: "3日"
        case .month: "月"
        }
    }

    var dayCount: Int {
        switch self {
        case .day: 1
        case .threeDay: 3
        case .month: 1
        }
    }
}

enum AppTab: Hashable {
    case schedule, planning, focus, stats
}

/// What the editor sheet is showing: an existing task, or a new one that isn't saved yet
enum EditorTarget: Identifiable, Equatable {
    case existing(UUID)
    case new(TaskSnapshot)

    var id: String {
        switch self {
        case .existing(let id): "existing-\(id)"
        case .new(let task): "new-\(task.id)"
        }
    }
}

/// Something the secretary noticed and offers to fix; the proposal is only built when the user asks
struct Suggestion: Identifiable {
    let id = UUID()
    let message: String
    let actionTitle: String
    let makeProposal: @MainActor () async -> PlanProposal?
}

/// UI state of the iPhone app (the macOS counterpart is `CalendarStore`, which carries Mac-only window state)
@MainActor
@Observable
final class ScheduleState {
    let calendar: Calendar
    var anchorDate: Date
    var mode: ScheduleMode = .threeDay
    var selectedTab: AppTab = .schedule
    var editor: EditorTarget?
    var isCapturePresented = false
    /// Bumped to ask the time grid to scroll to the current time
    var scrollToNowToken = 0
    /// Banner offering a fix (reflow after an interruption, splitting a task…)
    var suggestion: Suggestion?
    /// Task waiting for its pre-focus briefing sheet
    var briefingTask: TaskSnapshot?
    /// The clipboard holds text since the user last looked: show "粘贴为任务" next to the + button
    var hasClipboardHint = false
    @ObservationIgnored private var dismissedPasteboardChange = UserDefaults.standard.integer(forKey: "clipboardHint.dismissed")

    init(anchorDate: Date = .now, calendar: Calendar = .app) {
        self.calendar = calendar
        self.anchorDate = calendar.startOfDay(for: anchorDate)
    }

    /// First day shown: three-day mode starts on the anchor so "today" is the leftmost column
    var visibleDays: [Date] {
        (0..<mode.dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: anchorDate) }
    }

    var visibleInterval: DateInterval {
        let start = calendar.startOfDay(for: anchorDate)
        let end = calendar.date(byAdding: .day, value: mode.dayCount, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    var title: String {
        let components = calendar.dateComponents([.year, .month], from: anchorDate)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }

    func isToday(_ date: Date) -> Bool { calendar.isDateInToday(date) }

    func goToToday() {
        anchorDate = calendar.startOfDay(for: .now)
        scrollToNowToken += 1
    }

    /// Previous / next page: a day, three days, or a month
    func step(_ direction: Int) {
        switch mode {
        case .day, .threeDay:
            anchorDate = calendar.date(byAdding: .day, value: direction * mode.dayCount, to: anchorDate) ?? anchorDate
        case .month:
            anchorDate = calendar.date(byAdding: .month, value: direction, to: anchorDate) ?? anchorDate
        }
    }

    /// Shows a proposal on the calendar: switches to the schedule, three-day view, starting at its first item
    func showProposal(_ proposal: PlanProposal?, secretary: Secretary) {
        guard let proposal, !proposal.isEmpty else { return }
        secretary.present(proposal)
        if let first = proposal.items.map(\.operation.sortDate).filter({ $0 != .distantFuture }).min() {
            anchorDate = calendar.startOfDay(for: first)
            if mode == .month { mode = .threeDay }
        }
        selectedTab = .schedule
    }

    /// Checks (without reading it, so no paste prompt) whether there is new text on the clipboard
    func refreshClipboardHint() {
        let pasteboard = UIPasteboard.general
        hasClipboardHint = pasteboard.changeCount != dismissedPasteboardChange && (pasteboard.hasStrings || pasteboard.hasURLs)
    }

    func dismissClipboardHint() {
        dismissedPasteboardChange = UIPasteboard.general.changeCount
        UserDefaults.standard.set(dismissedPasteboardChange, forKey: "clipboardHint.dismissed")
        hasClipboardHint = false
    }

    func show(day: Date) {
        anchorDate = calendar.startOfDay(for: day)
        mode = .day
    }

    /// A new one-hour event starting at `start` (snapped by the caller)
    func newEvent(at start: Date, minutes: Int = 60) -> TaskSnapshot {
        TaskSnapshot(title: "", start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)),
                     isAllDay: false, source: .manual)
    }

    /// Default slot for the "+" button: next quarter hour today, or 9:00 on another day
    func defaultNewEventStart(now: Date = .now) -> Date {
        let day = calendar.startOfDay(for: anchorDate)
        if calendar.isDate(day, inSameDayAs: now) {
            let minute = calendar.component(.minute, from: now)
            let rounded = calendar.date(bySetting: .second, value: 0, of: now) ?? now
            return rounded.addingTimeInterval(TimeInterval((15 - minute % 15) * 60))
        }
        return calendar.date(byAdding: .hour, value: 9, to: day) ?? day
    }
}
