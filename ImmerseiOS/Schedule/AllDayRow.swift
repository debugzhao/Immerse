import ImmerseCore
import SwiftUI

/// All-day and multi-day events as bars above the time grid; a bar spans every visible day it covers
struct AllDayRow: View {
    let days: [Date]

    @Environment(ScheduleState.self) private var schedule
    @Environment(TaskStore.self) private var taskStore

    private static let maxLanes = 3

    private struct Bar: Identifiable {
        let task: TaskSnapshot
        let first: Int
        let last: Int
        var id: UUID { task.id }
    }

    var body: some View {
        let bars = makeBars()
        let lanes = EventLayoutEngine.allDayLanes(bars.map { (id: $0.id, startDay: $0.first, endDay: $0.last) })
        let visible = bars.filter { (lanes[$0.id] ?? 0) < Self.maxLanes }
        let laneCount = min((lanes.values.max() ?? -1) + 1, Self.maxLanes)

        if !bars.isEmpty {
            GeometryReader { geometry in
                let columnWidth = (geometry.size.width - GridMetrics.gutterWidth) / CGFloat(max(days.count, 1))
                ZStack(alignment: .topLeading) {
                    Text("全天")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: GridMetrics.gutterWidth - 6, alignment: .trailing)
                        .padding(.top, 4)
                    ForEach(visible) { bar in
                        let lane = CGFloat(lanes[bar.id] ?? 0)
                        barView(bar)
                            .frame(width: columnWidth * CGFloat(bar.last - bar.first + 1) - 3,
                                   height: GridMetrics.allDayLaneHeight - 3)
                            .padding(.leading, GridMetrics.gutterWidth + columnWidth * CGFloat(bar.first) + 1)
                            .padding(.top, lane * GridMetrics.allDayLaneHeight + 2)
                    }
                }
            }
            .frame(height: CGFloat(laneCount) * GridMetrics.allDayLaneHeight + 4)
            .overlay(alignment: .bottomTrailing) {
                let hidden = bars.count - visible.count
                if hidden > 0 {
                    Text("+\(hidden)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                }
            }
        }
    }

    private func barView(_ bar: Bar) -> some View {
        let task = bar.task
        let color = task.status == .done ? Color.gray : task.priority.color
        return Text(task.displayTitle)
            .font(.system(size: 11, weight: .semibold))
            .strikethrough(task.status == .done)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(color.opacity(Palette.eventFillOpacity), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 3)
            }
            .contentShape(Rectangle())
            .onTapGesture { schedule.editor = .existing(task.id) }
    }

    private func makeBars() -> [Bar] {
        guard let first = days.first else { return [] }
        let calendar = schedule.calendar
        return taskStore.tasks(in: schedule.visibleInterval)
            .filter(\.isAllDay)
            .map { task in
                let interval = task.displayInterval(in: calendar)
                let start = max(calendar.dayOffset(from: first, to: interval.start), 0)
                // displayInterval's end is exclusive midnight; the last covered day is the day before it
                let lastDay = interval.end.addingTimeInterval(-1)
                let end = min(calendar.dayOffset(from: first, to: lastDay), days.count - 1)
                return Bar(task: task, first: start, last: max(end, start))
            }
    }
}
