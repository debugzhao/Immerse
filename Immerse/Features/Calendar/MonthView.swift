import ImmerseCore
import SwiftUI

/// Month view: 6 rows × 7 columns, up to 3 events per cell, overflow shown as "+N"; click a date to open day view
struct MonthView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    private static let maxVisible = 3

    var body: some View {
        let days = gridDays
        let tasks = visibleTasks(days)

        VStack(spacing: 0) {
            weekdayHeader
            Divider()
            GeometryReader { geometry in
                grid(days: days, tasks: tasks, rowHeight: geometry.size.height / 6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func grid(days: [Date], tasks: [TaskSnapshot], rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        cell(days[row * 7 + column], tasks: tasks)
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight)
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, tasks: [TaskSnapshot]) -> MonthDayCell {
        MonthDayCell(day: day, tasks: self.tasks(for: day, in: tasks), maxVisible: Self.maxVisible)
    }

    private func visibleTasks(_ days: [Date]) -> [TaskSnapshot] {
        guard let first = days.first, let last = days.last,
              let end = store.calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        return taskStore.tasks(in: DateInterval(start: first, end: end))
    }

    private var weekdayHeader: some View {
        let calendar = store.calendar
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        let ordered = Array(symbols[shift...] + symbols[..<shift])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 32)
    }

    /// Fixed 42 days (6 weeks), starting from the Monday of the week containing the 1st
    private var gridDays: [Date] {
        let calendar = store.calendar
        // The month containing the anchor date, independent of the current mode: the month view stays alive while
        // hidden, and depending on the mode would re-lay-out all 42 cells on every day / week switch
        let monthStart = calendar.dateInterval(of: .month, for: store.anchorDate)?.start ?? calendar.startOfDay(for: store.anchorDate)
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func tasks(for day: Date, in tasks: [TaskSnapshot]) -> [TaskSnapshot] {
        let calendar = store.calendar
        guard let dayInterval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return tasks
            .filter { $0.displayInterval(in: calendar).overlapsHalfOpen(dayInterval) }
            .sorted { a, b in
                // All-day first, then by priority and start time
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                if a.priority != b.priority { return a.priority < b.priority }
                return a.start < b.start
            }
    }
}

private struct MonthDayCell: View {
    let day: Date
    let tasks: [TaskSnapshot]
    let maxVisible: Int

    @Environment(CalendarStore.self) private var store

    var body: some View {
        let calendar = store.calendar
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: store.anchorDate, toGranularity: .month)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Spacer()
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(minWidth: 22, minHeight: 22)
                    .background { if isToday { Circle().fill(Palette.nowIndicator) } }
            }
            ForEach(tasks.prefix(maxVisible)) { task in
                MonthEventRow(task: task)
            }
            if tasks.count > maxVisible {
                Text(verbatim: "+\(tasks.count - maxVisible)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(calendar.isWeekend(day) ? Palette.weekendTint : .clear)
        .overlay(alignment: .topLeading) {
            // Grid lines: draw the top and left edge of each cell
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Palette.gridLine).frame(height: 0.5)
                Rectangle().fill(Palette.gridLine).frame(width: 0.5)
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.select(nil)
            store.draft = nil
            store.anchorDate = day
            store.mode = .day
        }
        .onTapGesture { store.select(nil) }
        .acceptsPlanningDrop(allDay: true) { [day] _ in day }
        .opacity(inMonth ? 1 : 0.6)
    }
}

private struct MonthEventRow: View {
    let task: TaskSnapshot
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let isDone = task.status == .done
        let color = isDone ? Color.gray : task.priority.color
        let isSelected = store.selectedTaskID == task.id
        HStack(spacing: 4) {
            if task.isAllDay {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 12)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(TimeText.hhmm(task.start, calendar: store.calendar))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(task.displayTitle)
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(isSelected ? 0.3 : task.isAllDay ? 0.16 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.select(task.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.openEditor(task.id) })
        .taskContextMenu(task)
    }
}
