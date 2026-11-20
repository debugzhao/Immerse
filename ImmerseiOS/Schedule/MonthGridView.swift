import ImmerseCore
import SwiftUI

/// Month overview: weeks start on Monday, each cell lists up to 3 events; tapping a day opens it in day mode
struct MonthGridView: View {
    @Environment(ScheduleState.self) private var schedule
    @Environment(TaskStore.self) private var taskStore

    private static let maxListed = 3
    private var calendar: Calendar { schedule.calendar }

    var body: some View {
        let days = gridDays()
        let monthTasks = days.isEmpty ? [] : taskStore.tasks(in: DateInterval(start: days[0], end: calendar.date(byAdding: .day, value: 1, to: days[days.count - 1]) ?? days[0]))
        let month = calendar.component(.month, from: schedule.anchorDate)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortWeekdaySymbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in
                    cell(day, tasks: tasks(on: day, from: monthTasks), inMonth: calendar.component(.month, from: day) == month)
                }
            }
            Spacer(minLength: 0)
        }
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > 80, abs(value.translation.width) > abs(value.translation.height) else { return }
                withAnimation(Motion.snappy) { schedule.step(value.translation.width < 0 ? 1 : -1) }
            }
        )
    }

    private func cell(_ day: Date, tasks: [TaskSnapshot], inMonth: Bool) -> some View {
        let isToday = schedule.isToday(day)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption.weight(isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 22, height: 22)
                .background(isToday ? Palette.nowIndicator : .clear, in: Circle())
            ForEach(tasks.prefix(Self.maxListed)) { task in
                Text(task.displayTitle)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((task.status == .done ? Color.gray : task.priority.color).opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 3))
                    .strikethrough(task.status == .done)
            }
            if tasks.count > Self.maxListed {
                Text("+\(tasks.count - Self.maxListed)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .opacity(inMonth ? 1 : 0.55)
        .overlay(alignment: .top) { Rectangle().fill(Palette.gridLine).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.snappy) { schedule.show(day: day) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// Whole weeks covering the anchor's month
    private func gridDays() -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: schedule.anchorDate),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1)) else { return [] }
        var days: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    private func tasks(on day: Date, from all: [TaskSnapshot]) -> [TaskSnapshot] {
        let interval = DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
        return all
            .filter { $0.displayInterval(in: calendar).overlapsHalfOpen(interval) }
            .sorted { a, b in a.isAllDay != b.isAllDay ? a.isAllDay : a.start < b.start }
    }
}
