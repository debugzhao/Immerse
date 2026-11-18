import SwiftUI

/// 日期栏下方的全天行：全天 / 跨天任务画成横条，多条时分道堆叠
struct AllDayRowView: View {
    let days: [Date]
    let tasks: [TaskSnapshot]

    @Environment(CalendarStore.self) private var store

    private struct Bar: Identifiable {
        let task: TaskSnapshot
        let startDay: Int
        let endDay: Int
        var id: UUID { task.id }
    }

    var body: some View {
        let bars = makeBars()
        let lanes = EventLayoutEngine.allDayLanes(bars.map { ($0.id, $0.startDay, $0.endDay) })
        let laneCount = (lanes.values.max() ?? -1) + 1
        let height = max(CalendarMetrics.allDayMinHeight, CGFloat(laneCount) * CalendarMetrics.allDayLaneHeight + 6)

        HStack(spacing: 0) {
            Text("全天")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: CalendarMetrics.gutterWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)

            GeometryReader { geometry in
                let columnWidth = geometry.size.width / CGFloat(max(days.count, 1))
                ZStack(alignment: .topLeading) {
                    // 列分隔线，与下方时间网格对齐
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { _ in
                            Rectangle().fill(Palette.gridLine).frame(width: 0.5)
                            Spacer(minLength: 0)
                        }
                    }
                    ForEach(bars) { bar in
                        let lane = CGFloat(lanes[bar.id] ?? 0)
                        let span = CGFloat(bar.endDay - bar.startDay + 1)
                        AllDayBarView(task: bar.task, isSelected: store.selectedTaskID == bar.id)
                            .frame(width: columnWidth * span - 4, height: CalendarMetrics.allDayLaneHeight - 3)
                            .offset(x: columnWidth * CGFloat(bar.startDay) + 2,
                                    y: lane * CalendarMetrics.allDayLaneHeight + 3)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(Motion.snappy, value: laneCount)
    }

    private func makeBars() -> [Bar] {
        guard let first = days.first else { return [] }
        let calendar = store.calendar
        return tasks.compactMap { task in
            let interval = task.displayInterval(in: calendar)
            let startDay = calendar.dayOffset(from: first, to: interval.start)
            // 半开区间的末尾是次日 0 点，减 1 秒落回最后一天
            let endDay = calendar.dayOffset(from: first, to: interval.end.addingTimeInterval(-1))
            guard endDay >= 0, startDay < days.count else { return nil }
            return Bar(task: task, startDay: max(startDay, 0), endDay: min(endDay, days.count - 1))
        }
    }
}

private struct AllDayBarView: View {
    let task: TaskSnapshot
    let isSelected: Bool

    @Environment(CalendarStore.self) private var store

    private var isDone: Bool { task.status == .done }
    private var color: Color { isDone ? .gray : task.priority.color }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(task.title)
            .font(.system(size: 11, weight: .semibold))
            .strikethrough(isDone)
            .foregroundStyle(isDone ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(color.opacity(isSelected ? Palette.eventFillOpacitySelected : Palette.eventFillOpacity), in: shape)
            .overlay(alignment: .leading) {
                Rectangle().fill(color).frame(width: 3)
            }
            .clipShape(shape)
            .overlay {
                if isSelected { shape.strokeBorder(color, lineWidth: 1.2) }
            }
            .contentShape(shape)
            .onTapGesture { store.select(task.id) }
            .help("\(task.title)\n全天 · \(task.priority.title) · \(task.status.title)")
    }
}
