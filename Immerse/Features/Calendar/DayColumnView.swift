import SwiftUI

/// 一天的时间列：把当天的定时任务按重叠排布算法摆放
struct DayColumnView: View {
    let day: Date
    let tasks: [TaskSnapshot]

    @Environment(CalendarStore.self) private var store

    private struct Segment: Identifiable {
        let task: TaskSnapshot
        /// 截断到当天范围内的起止时间（跨午夜的任务会被拆成多段）
        let start: Date
        let end: Date
        var id: UUID { task.id }
    }

    var body: some View {
        let calendar = store.calendar
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        let segments = tasks.compactMap { task -> Segment? in
            let interval = task.displayInterval(in: calendar)
            guard interval.overlapsHalfOpen(dayInterval) else { return nil }
            return Segment(task: task, start: max(interval.start, dayStart), end: min(interval.end, dayEnd))
        }
        let placements = EventLayoutEngine.layout(
            segments.map { LayoutItem(id: $0.id, start: $0.start, end: $0.end, priority: $0.task.priority) },
            minimumDuration: CalendarMetrics.minimumEventDuration
        )

        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                // 点空白处取消选中
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { store.select(nil) }

                ForEach(segments) { segment in
                    if let placement = placements[segment.id] {
                        let columnWidth = width / CGFloat(placement.columnCount)
                        let top = CalendarMetrics.yOffset(for: segment.start, dayStart: dayStart)
                        let bottom = CalendarMetrics.yOffset(for: segment.end, dayStart: dayStart)
                        let height = max(bottom - top, CalendarMetrics.minimumEventHeight) - 2
                        EventBlockView(
                            task: segment.task,
                            isSelected: store.selectedTaskID == segment.task.id,
                            height: height
                        )
                        .frame(width: max(columnWidth * CGFloat(placement.span) - 3, 8), height: height)
                        .offset(x: columnWidth * CGFloat(placement.column) + 1, y: top + 1)
                    }
                }

                if store.isToday(day) {
                    NowIndicatorView(dayStart: dayStart)
                }
            }
        }
        .background(store.calendar.isWeekend(day) ? Palette.weekendTint : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.gridLine).frame(width: 0.5)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 当前时间红线：左端一个圆点，横贯今天这一列
private struct NowIndicatorView: View {
    let dayStart: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            let y = CalendarMetrics.yOffset(for: context.date, dayStart: dayStart)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Palette.nowIndicator)
                    .frame(height: 1.5)
                Circle()
                    .fill(Palette.nowIndicator)
                    .frame(width: 8, height: 8)
                    .offset(x: -4)
            }
            .offset(y: y - 4)
            .allowsHitTesting(false)
        }
    }
}
