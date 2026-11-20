import ImmerseCore
import SwiftUI

/// All-day row below the date bar: all-day / multi-day tasks drawn as horizontal bars, stacked in lanes when there are several.
/// Drag left/right to move the whole bar to other dates; double-click empty space to create an all-day event.
struct AllDayRowView: View {
    let days: [Date]
    let tasks: [TaskSnapshot]

    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @State private var drag: (task: TaskSnapshot, days: Int)?

    private struct Bar: Identifiable {
        let task: TaskSnapshot
        let startDay: Int
        let endDay: Int
        var id: UUID { task.id }
    }

    /// Changes whenever a bar moves, so it is rebuilt instead of keeping AppKit hit-testing from its old place
    private struct BarKey: Hashable {
        let id: UUID
        let startDay: Int
        let endDay: Int
        let lane: Int
    }

    var body: some View {
        let bars = makeBars()
        let lanes = EventLayoutEngine.allDayLanes(bars.map { ($0.id, $0.startDay, $0.endDay) })
        let laneCount = (lanes.values.max() ?? -1) + 1 + (draftDayIndex != nil ? 1 : 0)
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
                    // Column dividers + double-click-to-create hot zones, aligned with the time grid below
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            Rectangle().fill(Palette.gridLine).frame(width: 0.5)
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    store.select(nil)
                                    store.draft = DraftEvent(start: day, end: day, isAllDay: true)
                                }
                                .onTapGesture { store.select(nil) }
                                .acceptsPlanningDrop(allDay: true) { _ in day }
                        }
                    }

                    ForEach(bars) { bar in
                        let lane = CGFloat(lanes[bar.id] ?? 0)
                        let span = CGFloat(bar.endDay - bar.startDay + 1)
                        let shift = drag?.task.id == bar.id ? CGFloat(drag?.days ?? 0) : 0
                        AllDayBarView(task: bar.task, isSelected: store.selectedTaskID == bar.id)
                            .frame(width: columnWidth * span - 4, height: CalendarMetrics.allDayLaneHeight - 3)
                            .gesture(moveGesture(bar.task, columnWidth: columnWidth))
                            // Live drag feedback only; the resting position goes through layout (see DayColumnView)
                            .offset(x: columnWidth * shift)
                            .padding(.leading, columnWidth * CGFloat(bar.startDay) + 2)
                            .padding(.top, lane * CalendarMetrics.allDayLaneHeight + 3)
                            .id(BarKey(id: bar.id, startDay: bar.startDay, endDay: bar.endDay, lane: lanes[bar.id] ?? 0))
                    }

                    if let index = draftDayIndex {
                        draftBar
                            .frame(width: columnWidth - 4, height: CalendarMetrics.allDayLaneHeight - 3)
                            .offset(x: columnWidth * CGFloat(index) + 2,
                                    y: CGFloat(laneCount - 1) * CalendarMetrics.allDayLaneHeight + 3)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(Motion.snappy, value: laneCount)
    }

    private var draftDayIndex: Int? {
        guard let draft = store.draft, draft.isAllDay else { return nil }
        return days.firstIndex { store.calendar.isDate($0, inSameDayAs: draft.start) }
    }

    private var draftBar: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Text("新日程")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.14), in: shape)
            .overlay { shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
    }

    private func moveGesture(_ task: TaskSnapshot, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if drag == nil { store.select(task.id) }
                drag = (task, Int((value.translation.width / columnWidth).rounded()))
            }
            .onEnded { _ in
                defer { drag = nil }
                guard let days = drag?.days, days != 0 else { return }
                let updated = EventEditing.apply(.move, to: task, minutes: 0, days: days, calendar: store.calendar)
                taskStore.update(updated, actionName: "移动日程")
            }
    }

    private func makeBars() -> [Bar] {
        guard let first = days.first else { return [] }
        let calendar = store.calendar
        return tasks.compactMap { task in
            let interval = task.displayInterval(in: calendar)
            let startDay = calendar.dayOffset(from: first, to: interval.start)
            // The end of a half-open interval is midnight of the next day; subtract 1 second to land on the last day
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
        Text(task.displayTitle)
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
            .modifier(BreathingGlow(isActive: task.status == .inProgress, color: color))
            .contentShape(shape)
            .onTapGesture { store.select(task.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.openEditor(task.id) })
            .taskContextMenu(task)
            .help("\(task.displayTitle)\n全天 · \(task.priority.title) · \(task.status.title)")
    }
}
