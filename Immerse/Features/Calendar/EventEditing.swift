import Foundation

/// 拖拽方式
enum EventDragMode: Sendable {
    case move
    case resizeTop
    case resizeBottom
}

/// 拖拽移动 / 调整时长的计算。纯函数，便于单元测试。
enum EventEditing {
    /// 最短时长
    static let minimumDuration: TimeInterval = TimeInterval(CalendarMetrics.snapMinutes * 60)

    /// - Parameters:
    ///   - minutes: 竖直方向位移对应的分钟数（已吸附）
    ///   - days: 水平方向跨了几天（只对移动有效）
    static func apply(_ mode: EventDragMode, to task: TaskSnapshot, minutes: Int, days: Int,
                      calendar: Calendar = .app) -> TaskSnapshot {
        var result = task

        if task.isAllDay {
            // 全天任务只能整天移动
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
            // 只有开始时间的任务移动后仍然只有开始时间
            result.end = task.end.map { _ in shiftedStart.addingTimeInterval(interval.duration) }

        case .resizeBottom:
            result.end = max(interval.end.addingTimeInterval(delta), interval.start.addingTimeInterval(minimumDuration))

        case .resizeTop:
            result.start = min(interval.start.addingTimeInterval(delta), interval.end.addingTimeInterval(-minimumDuration))
            result.end = interval.end
        }
        return result
    }

    /// 编辑开始时间时保持时长不变（和系统日历一致）
    static func movingStart(of task: TaskSnapshot, to newStart: Date, calendar: Calendar = .app) -> TaskSnapshot {
        var result = task
        if let end = task.end {
            result.end = newStart.addingTimeInterval(end.timeIntervalSince(task.start))
        }
        result.start = newStart
        return result
    }
}
