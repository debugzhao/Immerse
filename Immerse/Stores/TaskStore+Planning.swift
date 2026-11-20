import Foundation

/// Inbox and goals: capture ideas, turn them into goals, schedule them onto the calendar. Every operation is one undo step
extension TaskStore {
    /// ⌘K / sidebar quick capture
    @discardableResult
    func captureIdea(_ title: String, now: Date = .now) -> TaskSnapshot? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return create(TaskSnapshot(title: trimmed, start: now, end: nil, isAllDay: false, kind: .idea),
                      actionName: "记录想法")
    }

    @discardableResult
    func createGoal(_ title: String, period: GoalPeriod, now: Date = .now, calendar: Calendar = .app) -> TaskSnapshot? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = period.range(containing: now, calendar: calendar)
        return create(TaskSnapshot(title: trimmed, start: range.start, end: range.lastDay, isAllDay: true, kind: .goal),
                      actionName: "新建目标")
    }

    /// Idea → goal for this week / month (keeps title, notes, priority)
    func makeGoal(_ id: UUID, period: GoalPeriod, now: Date = .now, calendar: Calendar = .app) {
        guard var task = task(id: id) else { return }
        let range = period.range(containing: now, calendar: calendar)
        task.kind = .goal
        task.sortOrder = nil   // a position in the Inbox means nothing among goals
        task.start = range.start
        task.end = range.lastDay
        task.isAllDay = true
        update(task, actionName: "设为目标")
    }

    /// Goal / scheduled event → back to the Inbox
    func moveToInbox(_ id: UUID, now: Date = .now) {
        guard var task = task(id: id) else { return }
        task.kind = .idea
        task.sortOrder = nil   // lands at the top of the Inbox like a fresh idea
        task.start = now
        task.end = nil
        task.isAllDay = false
        task.goalID = nil
        update(task, actionName: "移回收集箱")
    }

    /// Dropped on the calendar. An idea becomes an event at that time; a goal gets a new linked session.
    /// Returns the event that now sits on the calendar.
    @discardableResult
    func schedule(_ id: UUID, at start: Date, allDay: Bool = false, calendar: Calendar = .app) -> TaskSnapshot? {
        guard let source = task(id: id) else { return nil }
        let minutes = source.kind == .goal ? 60 : (source.plannedMinutes ?? 60)
        let day = calendar.startOfDay(for: start)
        switch source.kind {
        case .idea:
            var event = source
            event.kind = .event
            event.start = allDay ? day : start
            event.end = allDay ? nil : start.addingTimeInterval(TimeInterval(minutes * 60))
            event.isAllDay = allDay
            update(event, actionName: "安排想法")
            return event
        case .goal:
            let session = TaskSnapshot(
                title: source.title,
                start: allDay ? day : start,
                end: allDay ? nil : start.addingTimeInterval(TimeInterval(minutes * 60)),
                isAllDay: allDay,
                priority: source.priority,
                kind: .event,
                goalID: source.id
            )
            return create(session, actionName: "安排目标")
        case .event:
            // Dragging an existing event in from the search list etc. is a move; keep its duration
            var event = source
            let duration = source.displayInterval(in: calendar).duration
            event.start = allDay ? day : start
            event.end = allDay ? nil : start.addingTimeInterval(duration)
            event.isAllDay = allDay
            update(event, actionName: "移动日程")
            return event
        }
    }
}
