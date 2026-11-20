import Foundation
import ImmerseCore

/// After an interruption (a session abandoned or extended, an event missed), pushes the rest of the day back
/// in its original order, around fixed commitments; whatever no longer fits moves to the next day's best slots.
public enum Reflow {
    /// Events that can't move: off-site ones (they have a place), the one being focused on, and finished ones
    public static func isMovable(_ task: TaskSnapshot) -> Bool {
        task.kind == .event && !task.isAllDay && task.status == .todo && (task.place ?? "").isEmpty
    }

    public static func plan(day: Date, from start: Date, context: PlanningContext) -> PlanProposal? {
        let calendar = context.calendar
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let window = context.workday.window(on: day, calendar: calendar) else { return nil }
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)

        let todays = context.tasks.filter { $0.kind == .event && !$0.isAllDay && $0.displayInterval(in: calendar).overlapsHalfOpen(dayInterval) }
        // Missed (ended before `start` but not done) or still ahead; both get packed from `start` on
        let movable = todays.filter(isMovable).sorted { $0.start < $1.start }
        guard !movable.isEmpty else { return nil }
        let movableIDs = Set(movable.map(\.id))
        let fixed = context.busyIntervals(in: dayInterval, excluding: movableIDs)

        var cursor = SlotFinder.roundedUpToQuarter(max(start, window.start), calendar: calendar)
        var items: [PlanProposal.Item] = []
        var overflow: [TaskSnapshot] = []
        for task in movable {
            let duration = task.displayInterval(in: calendar).duration
            // Already fine where it is: starts after everything packed so far and doesn't collide
            if task.start >= cursor && !collides(DateInterval(start: task.start, duration: duration), with: fixed) {
                cursor = task.start.addingTimeInterval(duration)
                continue
            }
            guard let position = earliestFit(duration: duration, from: cursor, before: window.end, avoiding: fixed) else {
                overflow.append(task)
                continue
            }
            cursor = position.addingTimeInterval(duration)
            items.append(PlanProposal.Item(
                operation: .move(id: task.id, start: position, end: task.end.map { _ in position.addingTimeInterval(duration) }),
                reason: "顺延到 \(TimeText.hhmm(position, calendar: calendar))"))
        }

        if !overflow.isEmpty, let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
           let nextEnd = calendar.date(byAdding: .day, value: 1, to: nextDay) {
            // Overflow claims tomorrow's slots, with the moved items' new times counted as busy
            var tomorrowContext = context
            tomorrowContext.now = max(context.now, nextDay)
            let slots = SlotFinder.freeSlots(in: DateInterval(start: nextDay, end: nextEnd), context: tomorrowContext,
                                             excluding: Set(overflow.map(\.id)))
            let placed = Scheduler.plan(overflow, into: slots, context: tomorrowContext)
            for item in placed.items {
                guard case .update(let task) = item.operation else { continue }
                items.append(PlanProposal.Item(operation: .move(id: task.id, start: task.start, end: task.end),
                                               reason: "今天放不下，挪到明天 \(TimeText.hhmm(task.start, calendar: calendar))"))
            }
            for task in placed.unplaced {
                items.append(PlanProposal.Item(operation: .toInbox(id: task.id), reason: "今明两天都排不下，先放回收集箱"))
            }
        }

        guard !items.isEmpty else { return nil }
        return PlanProposal(origin: .reflow, summary: "顺延后面的 \(items.count) 项安排", items: items, createdAt: context.now)
    }

    static func collides(_ interval: DateInterval, with busy: [DateInterval]) -> Bool {
        busy.contains { $0.overlapsHalfOpen(interval) }
    }

    /// Earliest start ≥ `from` where `duration` fits before `limit` without touching `busy`
    static func earliestFit(duration: TimeInterval, from: Date, before limit: Date, avoiding busy: [DateInterval]) -> Date? {
        var candidate = from
        while candidate.addingTimeInterval(duration) <= limit {
            let interval = DateInterval(start: candidate, duration: duration)
            guard let blocker = busy.filter({ $0.overlapsHalfOpen(interval) }).max(by: { $0.end < $1.end }) else {
                return candidate
            }
            candidate = blocker.end
        }
        return nil
    }
}
