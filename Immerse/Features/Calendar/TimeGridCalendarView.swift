import SwiftUI

/// 日视图 / 周视图共用的时间网格：日期栏 + 全天行 + 可滚动的 24 小时网格
struct TimeGridCalendarView: View {
    let days: [Date]

    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var calendarStore

    private var calendar: Calendar { calendarStore.calendar }

    var body: some View {
        let tasks = taskStore.tasks(in: visibleInterval)
        let allDay = tasks.filter(\.isAllDay)
        let timed = tasks.filter { !$0.isAllDay }

        VStack(spacing: 0) {
            DayHeaderRow(days: days)
            AllDayRowView(days: days, tasks: allDay)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        TimeGutterView(showsNow: days.contains(where: calendarStore.isToday))
                            .frame(width: CalendarMetrics.gutterWidth)
                        ForEach(days, id: \.self) { day in
                            DayColumnView(day: day, tasks: timed)
                        }
                    }
                    .frame(height: CalendarMetrics.gridHeight)
                    .background(alignment: .topLeading) {
                        HourGridLines()
                            .padding(.leading, CalendarMetrics.gutterWidth)
                    }
                    // 留白，避免滚动到顶部时时间标签（向上偏移了半行字高）被截掉
                    .padding(.vertical, 10)
                }
                .onAppear {
                    proxy.scrollTo(CalendarMetrics.scrollAnchorID(CalendarMetrics.initialScrollHour), anchor: .top)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var visibleInterval: DateInterval {
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else {
            return DateInterval()
        }
        return DateInterval(start: first, end: end)
    }
}

// MARK: - 日期栏

private struct DayHeaderRow: View {
    let days: [Date]
    @Environment(CalendarStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            // 注意：不能用 Color.clear，它会在竖直方向撑满，把日期栏拉高
            Spacer().frame(width: CalendarMetrics.gutterWidth, height: 0)
            ForEach(days, id: \.self) { day in
                let isToday = store.isToday(day)
                HStack(spacing: 6) {
                    Text(TimeText.weekday(day, calendar: store.calendar))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isToday ? Palette.nowIndicator : .secondary)
                    Text(verbatim: "\(store.calendar.component(.day, from: day))")
                        .font(.system(size: 14, weight: isToday ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(minWidth: 24, minHeight: 24)
                        .background {
                            if isToday {
                                Circle().fill(Palette.nowIndicator)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CalendarMetrics.dayHeaderHeight)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    // 双击日期进入日视图
                    store.anchorDate = day
                    store.mode = .day
                }
            }
        }
    }
}

// MARK: - 时间刻度

private struct TimeGutterView: View {
    let showsNow: Bool
    @Environment(CalendarStore.self) private var store

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                        if hour > 0 {
                            Text(String(format: "%02d:00", hour))
                                .font(.system(size: 10, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .offset(y: -6)
                                .padding(.trailing, 8)
                        }
                    }
                    .frame(height: CalendarMetrics.hourHeight)
                }
            }
            // 滚动定位锚点：放在整点上方 12pt，滚动后时间标签能完整显示
            // （必须改变布局位置，offset 只影响绘制，scrollTo 不认）
            ForEach(0..<24, id: \.self) { hour in
                VStack(spacing: 0) {
                    Spacer().frame(height: max(CGFloat(hour) * CalendarMetrics.hourHeight - 12, 0))
                    // 用字符串 id：ForEach 元素自身的整数 id 也会被 scrollTo 匹配到，必须区分开
                    Color.clear.frame(width: 1, height: 1).id(CalendarMetrics.scrollAnchorID(hour))
                    Spacer(minLength: 0)
                }
            }
            if showsNow {
                TimelineView(.everyMinute) { context in
                    let dayStart = store.calendar.startOfDay(for: context.date)
                    Text(TimeText.hhmm(context.date, calendar: store.calendar))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.nowIndicator))
                        .offset(y: CalendarMetrics.yOffset(for: context.date, dayStart: dayStart) - 7)
                        .padding(.trailing, 4)
                }
            }
        }
    }
}

// MARK: - 网格线

private struct HourGridLines: View {
    var body: some View {
        Canvas { context, size in
            let color = Palette.gridLine
            for hour in 1..<24 {
                let y = CGFloat(hour) * CalendarMetrics.hourHeight
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
        }
        .frame(height: CalendarMetrics.gridHeight)
        .allowsHitTesting(false)
    }
}
