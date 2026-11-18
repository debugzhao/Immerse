import SwiftUI

/// 侧栏迷你月历：点日期跳转，高亮今天和当前正在看的周
struct MiniMonthView: View {
    @Environment(CalendarStore.self) private var store
    /// 迷你月历自己翻页，不影响主日历；主日历跳到别的月份时再同步过来
    @State private var displayedMonth: Date = .now

    private var calendar: Calendar { store.calendar }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdayRow
            VStack(spacing: 2) {
                ForEach(weeks, id: \.self) { week in
                    weekRow(week)
                }
            }
        }
        .onAppear { displayedMonth = monthStart(of: store.anchorDate) }
        .onChange(of: store.anchorDate) { _, newValue in
            withAnimation(Motion.snappy) { displayedMonth = monthStart(of: newValue) }
        }
    }

    private var header: some View {
        HStack {
            // 用 verbatim：普通的 Text 插值会按本地化格式化数字，年份会变成「2,026」
            Text(verbatim: "\(calendar.component(.year, from: displayedMonth))年\(calendar.component(.month, from: displayedMonth))月")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
        .imageScale(.small)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekRow(_ week: [Date]) -> some View {
        // DateInterval.contains 是闭区间，会把下周一 0 点也算进来，这里按半开区间判断
        let visible = store.visibleInterval
        let isVisibleWeek = store.mode == .week && week.contains { $0 >= visible.start && $0 < visible.end }
        return HStack(spacing: 0) {
            ForEach(week, id: \.self) { day in
                dayCell(day)
            }
        }
        .background {
            if isVisibleWeek {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isSelectedDay = store.mode == .day && calendar.isDate(day, inSameDayAs: store.anchorDate)

        return Text(verbatim: "\(calendar.component(.day, from: day))")
            .font(.system(size: 11, weight: isToday ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(width: 22, height: 22)
            .background {
                if isToday {
                    Circle().fill(Palette.nowIndicator)
                } else if isSelectedDay {
                    Circle().fill(Color.accentColor.opacity(0.2))
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { store.anchorDate = day }
    }

    // MARK: - 日期计算

    private func monthStart(of date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    private func shiftMonth(_ value: Int) {
        withAnimation(Motion.snappy) {
            displayedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
        }
    }

    /// 按每周第一天重新排序的星期符号：「一 二 三 四 五 六 日」
    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// 固定 6 行，避免翻月时高度跳动
    private var weeks: [[Date]] {
        let start = monthStart(of: displayedMonth)
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: start) else { return [] }
        let days = (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
        return stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<$0 + 7]) }
    }
}
