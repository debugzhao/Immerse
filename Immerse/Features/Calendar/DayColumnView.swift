import AppKit
import SwiftUI

/// One day's time column: lays out that day's timed tasks and handles drag-to-create, move, and resize
struct DayColumnView: View {
    let day: Date
    let tasks: [TaskSnapshot]

    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    /// New event being rubber-banded (converted to store.draft on release)
    @State private var creating: DraftEvent?
    /// Event being dragged
    @State private var activeDrag: ActiveDrag?

    private struct ActiveDrag {
        let task: TaskSnapshot
        let mode: EventDragMode
        var translation: CGSize
    }

    private struct Segment: Identifiable {
        let task: TaskSnapshot
        /// Start/end clamped to the day (tasks crossing midnight are split into multiple segments)
        let start: Date
        let end: Date
        var id: UUID { task.id }
    }

    private var calendar: Calendar { store.calendar }
    private var dayStart: Date { calendar.startOfDay(for: day) }

    var body: some View {
        let segments = makeSegments()
        let items = segments.map { LayoutItem(id: $0.id, start: $0.start, end: $0.end, priority: $0.task.priority) }
        let placements = EventLayoutEngine.layout(items, minimumDuration: CalendarMetrics.minimumEventDuration)
        let displayEnds = EventLayoutEngine.displayEnds(items, minimumDuration: CalendarMetrics.minimumEventDuration)

        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                background(width: width)

                ForEach(segments) { segment in
                    if let placement = placements[segment.id] {
                        block(for: segment, placement: placement, displayEnd: displayEnds[segment.id] ?? segment.end,
                              columnWidth: width)
                    }
                }

                if let drag = activeDrag {
                    dragPreview(drag, columnWidth: width)
                }

                if let draft = visibleDraft {
                    draftBlock(draft, width: width)
                }

                if store.isToday(day) {
                    NowIndicatorView(dayStart: dayStart)
                }
            }
        }
        .acceptsPlanningDrop(allDay: false) { [dayStart] location in
            CalendarMetrics.date(forY: location.y - 8, dayStart: dayStart)
        }
        .background(calendar.isWeekend(day) ? Palette.weekendTint : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.gridLine).frame(width: 0.5).allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        // A dragged event may cross into adjacent columns; raise this column to the top so it isn't covered
        .zIndex(activeDrag != nil ? 1 : 0)
    }

    // MARK: - Background: drag to create / double-click to create / click empty space to deselect

    private func background(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let a = CalendarMetrics.date(forY: value.startLocation.y, dayStart: dayStart)
                        let b = CalendarMetrics.date(forY: value.location.y, dayStart: dayStart)
                        let start = min(a, b)
                        let end = max(max(a, b), start.addingTimeInterval(EventEditing.minimumDuration))
                        store.select(nil)
                        creating = DraftEvent(start: start, end: end)
                    }
                    .onEnded { _ in
                        store.draft = creating
                        creating = nil
                    }
            )
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                // Double-click empty space: create a 1-hour event at that position
                let start = CalendarMetrics.date(forY: location.y - CalendarMetrics.hourHeight / 4, dayStart: dayStart)
                store.select(nil)
                store.draft = DraftEvent(start: start, end: start.addingTimeInterval(3600))
            }
            .onTapGesture {
                store.select(nil)
                store.draft = nil
            }
    }

    // MARK: - Event blocks

    @ViewBuilder
    private func block(for segment: Segment, placement: LayoutPlacement, displayEnd: Date, columnWidth: CGFloat) -> some View {
        let slotWidth = columnWidth / CGFloat(placement.columnCount)
        let top = CalendarMetrics.yOffset(for: segment.start, dayStart: dayStart)
        let bottom = CalendarMetrics.yOffset(for: displayEnd, dayStart: dayStart)
        let height = max(bottom - top - 2, 4)
        // Compact blocks keep a grabbable middle for moving: shrink the resize hot zones
        let handleHeight: CGFloat = height < 16 ? 3 : 6
        let isDragging = activeDrag?.task.id == segment.task.id

        EventBlockView(
            task: segment.task,
            isSelected: store.selectedTaskID == segment.task.id,
            height: height
        )
        .frame(width: max(slotWidth * CGFloat(placement.span) - 3, 8), height: height)
        .overlay(alignment: .top) {
            ResizeHandle(height: handleHeight).gesture(dragGesture(segment.task, mode: .resizeTop, columnWidth: columnWidth))
        }
        .overlay(alignment: .bottom) {
            ResizeHandle(height: handleHeight).gesture(dragGesture(segment.task, mode: .resizeBottom, columnWidth: columnWidth))
        }
        .gesture(dragGesture(segment.task, mode: .move, columnWidth: columnWidth))
        .opacity(isDragging ? 0.35 : 1)
        .offset(x: slotWidth * CGFloat(placement.column) + 1, y: top + 1)
    }

    private func dragGesture(_ task: TaskSnapshot, mode: EventDragMode, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if activeDrag == nil {
                    store.select(task.id)
                    store.draggingTaskID = task.id
                }
                activeDrag = ActiveDrag(task: task, mode: mode, translation: value.translation)
            }
            .onEnded { value in
                let updated = preview(task: task, mode: mode, translation: value.translation, columnWidth: columnWidth)
                activeDrag = nil
                store.draggingTaskID = nil
                if updated != task {
                    taskStore.update(updated, actionName: mode == .move ? "移动日程" : "调整时长")
                }
            }
    }

    private func preview(task: TaskSnapshot, mode: EventDragMode, translation: CGSize, columnWidth: CGFloat) -> TaskSnapshot {
        let minutes = CalendarMetrics.snappedMinutes(forDeltaY: translation.height)
        let days = mode == .move && columnWidth > 0 ? Int((translation.width / columnWidth).rounded()) : 0
        return EventEditing.apply(mode, to: task, minutes: minutes, days: days, calendar: calendar)
    }

    /// Preview block while dragging: drawn at the target position, leaving a translucent ghost at the original
    private func dragPreview(_ drag: ActiveDrag, columnWidth: CGFloat) -> some View {
        let updated = preview(task: drag.task, mode: drag.mode, translation: drag.translation, columnWidth: columnWidth)
        let interval = updated.displayInterval(in: calendar)
        let targetDayStart = calendar.startOfDay(for: interval.start)
        let dayShift = calendar.dayOffset(from: dayStart, to: targetDayStart)
        let top = CalendarMetrics.yOffset(for: interval.start, dayStart: targetDayStart)
        let visibleEnd = min(interval.end, targetDayStart.addingTimeInterval(24 * 3600))
        let height = max(CalendarMetrics.yOffset(for: visibleEnd, dayStart: targetDayStart) - top,
                         CalendarMetrics.minimumEventHeight) - 2

        return EventBlockView(task: updated, isSelected: true, height: height)
            .frame(width: columnWidth - 4, height: height)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            .offset(x: CGFloat(dayShift) * columnWidth + 2, y: top + 1)
            .allowsHitTesting(false)
    }

    // MARK: - Draft

    private var visibleDraft: DraftEvent? {
        if let creating { return creating }
        guard let draft = store.draft, !draft.isAllDay,
              calendar.isDate(draft.start, inSameDayAs: day) else { return nil }
        return draft
    }

    private func draftBlock(_ draft: DraftEvent, width: CGFloat) -> some View {
        let top = CalendarMetrics.yOffset(for: draft.start, dayStart: dayStart)
        let height = max(CalendarMetrics.yOffset(for: draft.end, dayStart: dayStart) - top,
                         CalendarMetrics.minimumEventHeight) - 2
        return DraftBlockView(draft: draft)
            .frame(width: width - 4, height: height)
            .offset(x: 2, y: top + 1)
    }

    // MARK: - Data

    private func makeSegments() -> [Segment] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        return tasks.compactMap { task -> Segment? in
            let interval = task.displayInterval(in: calendar)
            guard interval.overlapsHalfOpen(dayInterval) else { return nil }
            return Segment(task: task, start: max(interval.start, dayStart), end: min(interval.end, dayEnd))
        }
    }
}

/// Drag hot zones on the top/bottom edges of an event block; shows a resize cursor on hover
private struct ResizeHandle: View {
    var height: CGFloat = 6

    var body: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }
}

/// New event being selected / awaiting a name: dashed outline
private struct DraftBlockView: View {
    let draft: DraftEvent
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            Text("新日程")
                .font(.system(size: 12, weight: .semibold))
            Text(TimeText.range(draft.start, draft.end, calendar: store.calendar))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.accentColor.opacity(0.14), in: shape)
        .overlay { shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
        .allowsHitTesting(false)
    }
}

/// Current-time red line: a dot on the left end, spanning today's column
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
