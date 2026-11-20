import ImmerseCore
import SwiftUI

/// An event being dragged after a long press: moved, or resized from its bottom edge
struct GridDrag: Equatable {
    var task: TaskSnapshot
    var mode: EventDragMode
    var translation: CGSize = .zero
    /// Last snapped position, so the haptic tick fires once per 15-minute step
    var lastStep: Int = 0
    var lastDay: Int = 0
}

/// Hour gutter plus one column per visible day, inside a vertical scroll view
struct TimeGridView: View {
    let days: [Date]

    @Environment(ScheduleState.self) private var schedule
    @Environment(TaskStore.self) private var taskStore
    @State private var drag: GridDrag?

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = max((geometry.size.width - GridMetrics.gutterWidth) / CGFloat(max(days.count, 1)), 1)
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        HourGutter()
                        ForEach(days, id: \.self) { day in
                            DayColumn(day: day, columnWidth: columnWidth, drag: $drag)
                                .frame(width: columnWidth)
                        }
                    }
                    .frame(height: GridMetrics.gridHeight)
                    .padding(.vertical, 8)
                }
                .scrollDisabled(drag != nil)
                .onAppear { scrollToStart(proxy, animated: false) }
                .onChange(of: schedule.scrollToNowToken) { scrollToStart(proxy, animated: true) }
            }
            // Horizontal swipe pages through days; ignored while an event is being dragged
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard drag == nil,
                              abs(value.translation.width) > 80,
                              abs(value.translation.width) > abs(value.translation.height) * 2 else { return }
                        withAnimation(Motion.snappy) { schedule.step(value.translation.width < 0 ? 1 : -1) }
                    }
            )
        }
    }

    private func scrollToStart(_ proxy: ScrollViewProxy, animated: Bool) {
        let showsToday = days.contains { schedule.isToday($0) }
        let hour = showsToday
            ? max(schedule.calendar.component(.hour, from: .now) - 1, 0)
            : GridMetrics.initialScrollHour
        if animated {
            withAnimation(Motion.gentle) { proxy.scrollTo(HourGutter.anchorID(hour), anchor: .top) }
        } else {
            proxy.scrollTo(HourGutter.anchorID(hour), anchor: .top)
        }
    }
}

/// "09:00" labels down the left edge; each hour carries a scroll anchor
struct HourGutter: View {
    static func anchorID(_ hour: Int) -> String { "hour-\(hour)" }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : String(format: "%02d:00", hour))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: GridMetrics.gutterWidth - 6, height: GridMetrics.hourHeight, alignment: .topTrailing)
                    .offset(y: -7)
                    .id(Self.anchorID(hour))
            }
        }
        .frame(width: GridMetrics.gutterWidth, alignment: .leading)
    }
}

/// One day's column: grid lines, timed events laid out side by side, the drag preview and the now line
struct DayColumn: View {
    let day: Date
    let columnWidth: CGFloat
    @Binding var drag: GridDrag?

    @Environment(ScheduleState.self) private var schedule
    @Environment(TaskStore.self) private var taskStore

    private var calendar: Calendar { schedule.calendar }
    private var dayStart: Date { calendar.startOfDay(for: day) }

    private struct Segment: Identifiable {
        let task: TaskSnapshot
        let start: Date
        let end: Date
        var id: UUID { task.id }
    }

    var body: some View {
        let segments = makeSegments()
        let items = segments.map { LayoutItem(id: $0.id, start: $0.start, end: $0.end, priority: $0.task.priority) }
        let placements = EventLayoutEngine.layout(items, minimumDuration: GridMetrics.minimumEventDuration)
        let displayEnds = EventLayoutEngine.displayEnds(items, minimumDuration: GridMetrics.minimumEventDuration)

        ZStack(alignment: .topLeading) {
            gridBackground
            ForEach(segments) { segment in
                if let placement = placements[segment.id] {
                    block(segment, placement: placement, displayEnd: displayEnds[segment.id] ?? segment.end)
                }
            }
            if let drag, isPreviewDay(for: drag) {
                preview(for: drag)
            }
            if schedule.isToday(day) {
                NowLine(dayStart: dayStart)
            }
        }
        .frame(height: GridMetrics.gridHeight, alignment: .top)
        .background(calendar.isWeekend(day) ? Palette.weekendTint : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.gridLine).frame(width: 0.5).allowsHitTesting(false)
        }
        // The dragged block may leave this column; keep its column above the neighbours
        .zIndex(drag.map { isSameDay($0.task.start) } == true ? 1 : 0)
    }

    private var gridBackground: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle()
                    .fill(Palette.gridLine)
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            // Tap empty space: a one-hour event starting at that quarter hour
            let start = GridMetrics.date(forY: location.y, dayStart: dayStart)
            schedule.editor = .new(schedule.newEvent(at: start))
        }
    }

    @ViewBuilder
    private func block(_ segment: Segment, placement: LayoutPlacement, displayEnd: Date) -> some View {
        let slotWidth = columnWidth / CGFloat(placement.columnCount)
        let top = GridMetrics.y(for: segment.start, dayStart: dayStart)
        let height = max(GridMetrics.y(for: displayEnd, dayStart: dayStart) - top - 2, 6)
        let isDragging = drag?.task.id == segment.task.id

        EventBlock(task: segment.task, height: height, isLifted: false)
            .frame(width: max(slotWidth * CGFloat(placement.span) - 2, 8), height: height)
            .overlay(alignment: .bottom) {
                // Resize from the bottom edge; only on blocks tall enough to keep a grabbable middle
                if height >= 40 {
                    Color.clear
                        .frame(height: 14)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(segment.task, mode: .resizeBottom))
                }
            }
            .onTapGesture { schedule.editor = .existing(segment.task.id) }
            .gesture(dragGesture(segment.task, mode: .move))
            .opacity(isDragging ? 0.3 : 1)
            .padding(.leading, slotWidth * CGFloat(placement.column) + 1)
            .padding(.top, top + 1)
            .accessibilityElement(children: .combine)
            .accessibilityHint("轻点编辑，长按拖动可移动")
    }

    /// Long press lifts the event (haptic), then dragging moves or resizes it in 15-minute steps
    private func dragGesture(_ task: TaskSnapshot, mode: EventDragMode) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let dragValue) = value else { return }
                if drag == nil {
                    drag = GridDrag(task: task, mode: mode)
                    Haptics.pickUp()
                }
                guard let dragValue, var current = drag else { return }
                current.translation = dragValue.translation
                let step = GridMetrics.snappedMinutes(forDeltaY: dragValue.translation.height)
                let dayOffset = mode == .move ? Int((dragValue.translation.width / columnWidth).rounded()) : 0
                if step != current.lastStep || dayOffset != current.lastDay {
                    current.lastStep = step
                    current.lastDay = dayOffset
                    Haptics.step()
                }
                drag = current
            }
            .onEnded { value in
                defer { drag = nil }
                guard case .second(true, let dragValue?) = value else { return }
                let updated = applied(task, mode: mode, translation: dragValue.translation)
                if updated != task {
                    taskStore.update(updated, actionName: mode == .move ? "移动日程" : "调整时长")
                    Haptics.success()
                }
            }
    }

    private func applied(_ task: TaskSnapshot, mode: EventDragMode, translation: CGSize) -> TaskSnapshot {
        let minutes = GridMetrics.snappedMinutes(forDeltaY: translation.height)
        let days = mode == .move ? Int((translation.width / columnWidth).rounded()) : 0
        return EventEditing.apply(mode, to: task, minutes: minutes, days: days, calendar: calendar)
    }

    private func isSameDay(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: day) }

    /// The preview is drawn by the column the event started in, offset sideways into the target column
    private func isPreviewDay(for drag: GridDrag) -> Bool { isSameDay(drag.task.start) }

    private func preview(for drag: GridDrag) -> some View {
        let updated = applied(drag.task, mode: drag.mode, translation: drag.translation)
        let dayShift = drag.mode == .move ? CGFloat(Int((drag.translation.width / columnWidth).rounded())) : 0
        let shiftedDayStart = calendar.startOfDay(for: updated.start)
        let interval = updated.displayInterval(in: calendar)
        let top = GridMetrics.y(for: interval.start, dayStart: shiftedDayStart)
        let end = max(interval.end, interval.start.addingTimeInterval(GridMetrics.minimumEventDuration))
        let height = max(GridMetrics.y(for: end, dayStart: shiftedDayStart) - top - 2, 6)
        return EventBlock(task: updated, height: height, isLifted: true)
            .frame(width: columnWidth - 2, height: height)
            .overlay(alignment: .topLeading) {
                Text(TimeText.range(interval.start, interval.end, calendar: calendar))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -22)
            }
            .padding(.leading, dayShift * columnWidth + 1)
            .padding(.top, top + 1)
            .allowsHitTesting(false)
    }

    private func makeSegments() -> [Segment] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        return taskStore.tasks(in: dayInterval).filter { !$0.isAllDay }.compactMap { task in
            let interval = task.displayInterval(in: calendar)
            guard interval.overlapsHalfOpen(dayInterval) else { return nil }
            return Segment(task: task, start: max(interval.start, dayStart), end: min(interval.end, dayEnd))
        }
    }
}

/// The red "now" line across today's column, refreshed every minute
struct NowLine: View {
    let dayStart: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 0) {
                Circle().fill(Palette.nowIndicator).frame(width: 8, height: 8)
                Rectangle().fill(Palette.nowIndicator).frame(height: 1.5)
            }
            .offset(x: -4, y: GridMetrics.y(for: context.date, dayStart: dayStart) - 4)
        }
        .allowsHitTesting(false)
    }
}

/// One event in the grid: translucent priority fill, left color bar, title and time
struct EventBlock: View {
    let task: TaskSnapshot
    let height: CGFloat
    let isLifted: Bool

    @Environment(ScheduleState.self) private var schedule
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDone: Bool { task.status == .done }
    private var color: Color { isDone ? .gray : task.priority.color }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                (task.goalID != nil ? Text(Image(systemName: "target")) + Text(" ") + Text(task.displayTitle) : Text(task.displayTitle))
                    .font(.system(size: height < 24 ? 10 : 12, weight: .semibold))
                    .strikethrough(isDone)
                    .lineLimit(max(1, Int((height - (height >= 40 ? 20 : 4)) / 15)))
                if height >= 40 {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isDone ? .secondary : .primary)
            .padding(.horizontal, 4)
            .padding(.vertical, height >= 24 ? 3 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: height < 24 ? .leading : .topLeading)
        }
        .background(color.opacity(isLifted ? Palette.eventFillOpacityDragging
                                  : isDone ? Palette.eventFillOpacityDone : Palette.eventFillOpacity), in: shape)
        .background(isLifted ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear), in: shape)
        .clipShape(shape)
        .overlay {
            if task.status == .inProgress || isLifted {
                shape.strokeBorder(color, lineWidth: 1.5)
            }
        }
        .shadow(color: isLifted ? .black.opacity(0.2) : .clear, radius: 8, y: 4)
        .scaleEffect(isLifted && !reduceMotion ? 1.02 : 1)
        .contentShape(shape)
    }

    private var subtitle: String {
        let interval = task.displayInterval(in: schedule.calendar)
        let time = TimeText.range(interval.start, interval.end, calendar: schedule.calendar)
        guard let place = task.place, !place.isEmpty else { return time }
        return "\(time) · \(place)"
    }
}
