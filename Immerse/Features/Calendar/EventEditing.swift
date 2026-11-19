import Foundation

/// Drag mode
enum EventDragMode: Sendable {
    case move
    case resizeTop
    case resizeBottom
}

/// Computation for drag-to-move / resize. Pure function, easy to unit test.
enum EventEditing {
    /// Minimum duration
    static let minimumDuration: TimeInterval = TimeInterval(CalendarMetrics.snapMinutes * 60)

    /// - Parameters:
    ///   - minutes: vertical offset in minutes (already snapped)
    ///   - days: days spanned horizontally (only applies to moves)
    static func apply(_ mode: EventDragMode, to task: TaskSnapshot, minutes: Int, days: Int,
                      calendar: Calendar = .app) -> TaskSnapshot {
        var result = task

        if task.isAllDay {
            // All-day tasks can only move by whole days
            guard mode == .move, days != 0 else { return task }
            result.start = calendar.date(byAdding: .day, value: days, to: task.start) ?? task.start
            result.end = task.end.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
            return result
        }

        let interval = task.displayInterval(in: calendar)
        let delta = TimeInterval(minutes * 60)

        switch mode {
        case .move:
            let shiftedStart = (calendar.date(byAdding: .day, value: days, to: interval.start) ?? interval.start)
                .addingTimeInterval(delta)
            result.start = shiftedStart
            // A task with only a start time still has only a start time after moving
            result.end = task.end.map { _ in shiftedStart.addingTimeInterval(interval.duration) }

        case .resizeBottom:
            result.end = max(interval.end.addingTimeInterval(delta), interval.start.addingTimeInterval(minimumDuration))

        case .resizeTop:
            result.start = min(interval.start.addingTimeInterval(delta), interval.end.addingTimeInterval(-minimumDuration))
            result.end = interval.end
        }
        return result
    }

    /// Keep the duration unchanged when editing the start time (matches the system Calendar)
    static func movingStart(of task: TaskSnapshot, to newStart: Date, calendar: Calendar = .app) -> TaskSnapshot {
        var result = task
        if let end = task.end {
            result.end = newStart.addingTimeInterval(end.timeIntervalSince(task.start))
        }
        result.start = newStart
        return result
    }
}
