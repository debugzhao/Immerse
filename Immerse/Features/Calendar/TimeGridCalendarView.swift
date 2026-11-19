import SwiftUI

/// Time grid shared by day / week views: date bar + all-day row + scrollable 24-hour grid
struct TimeGridCalendarView: View {
    let days: [Date]

    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(FocusEngine.self) private var focusEngine
    /// Hour shown at the top on the very first frame. Fixed when the grid is created, so the grid opens already in place
    /// instead of rendering at 00:00 and jumping (programmatic scrolling after appear caused a visible jump on every switch)
    @State private var initialHour: Int?
    /// Start remembering the scroll position only after the initial scroll, otherwise the first layout records 00:00
    @State private var tracksScroll = false
    /// Scroll bars stay hidden while the grid appears: a freshly created NSScrollView plus the initial
    /// programmatic scroll would otherwise flash the scroller on every day / week / month switch
    @State private var showsScrollIndicators = false

    private var calendar: Calendar { calendarStore.calendar }

    var body: some View {
        let tasks = taskStore.tasks(in: visibleInterval).filter(calendarStore.passesFilter)
        let allDay = tasks.filter(\.isAllDay)
        let timed = tasks.filter { !$0.isAllDay }
        // One query for the whole visible range; each column filters its own day (was one query per column)
        let records = FocusRecord.onCalendar(focusEngine.records(in: visibleInterval)) { taskStore.task(id: $0) != nil }

        VStack(spacing: 0) {
            DayHeaderRow(days: days)
            AllDayRowView(days: days, tasks: allDay)
            Divider()
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        TimeGutterView(showsNow: days.contains(where: calendarStore.isToday))
                            .frame(width: CalendarMetrics.gutterWidth)
                        ForEach(days, id: \.self) { day in
                            DayColumnView(day: day, tasks: timed, records: records)
                        }
                    }
                    .frame(height: CalendarMetrics.gridHeight)
                    .background(alignment: .topLeading) {
                        HourGridLines()
                            .padding(.leading, CalendarMetrics.gutterWidth)
                    }
                    // Spacer so the time label (offset up by half a line height) isn't clipped when scrolled to the top
                    .padding(.vertical, 10)
                    // Remember which hour is at the top, so a recreated grid (day ↔ week switch) can scroll back to it
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: GridScrollOffsetKey.self,
                                                   value: geometry.frame(in: .named("timeGrid")).minY)
                        }
                    }
                }
                .defaultScrollAnchor(tracksScroll ? nil : initialAnchor(viewportHeight: viewport.size.height))
                .scrollIndicators(showsScrollIndicators ? .automatic : .hidden)
                .coordinateSpace(name: "timeGrid")
                .onPreferenceChange(GridScrollOffsetKey.self) { [calendarStore, tracksScroll] minY in
                    guard tracksScroll else { return }
                    let hour = min(max(Int(((-minY) / CalendarMetrics.hourHeight).rounded()), 0), 23)
                    // Preference callbacks are delivered on the main thread
                    MainActor.assumeIsolated { calendarStore.lastScrollHour = hour }
                }
                .task {
                    // The first frame is already positioned by defaultScrollAnchor; from now on follow the user's scrolling
                    try? await Task.sleep(for: .milliseconds(50))
                    tracksScroll = true
                    // Bring the scroll bars back once the switch animation has settled
                    try? await Task.sleep(for: .milliseconds(250))
                    showsScrollIndicators = true
                }
                .onChange(of: calendarStore.scrollRequest) { _, request in
                    withAnimation(Motion.gentle) {
                        proxy.scrollTo(CalendarMetrics.scrollAnchorID(request.hour), anchor: .top)
                    }
                }
            }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if initialHour == nil { initialHour = calendarStore.lastScrollHour ?? calendarStore.scrollRequest.hour }
        }
    }

    /// Unit-point anchor that puts `hour` at the top of the viewport on the first frame.
    /// defaultScrollAnchor aligns the anchor point of the content with the same point of the viewport, so for a
    /// target offset `o`: y = o / (contentHeight − viewportHeight)
    private func initialAnchor(viewportHeight: CGFloat) -> UnitPoint {
        let hour = initialHour ?? calendarStore.lastScrollHour ?? calendarStore.scrollRequest.hour
        let contentHeight = CalendarMetrics.gridHeight + 20          // grid + vertical padding
        // Same position the scroll anchors use: 12 pt above the hour line, below the 10 pt top padding
        let offset = max(10 + CGFloat(hour) * CalendarMetrics.hourHeight - 12, 0)
        let scrollable = max(contentHeight - viewportHeight, 1)
        return UnitPoint(x: 0, y: min(offset / scrollable, 1))
    }

    private var visibleInterval: DateInterval {
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else {
            return DateInterval()
        }
        return DateInterval(start: first, end: end)
    }
}

private struct GridScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Date bar

private struct DayHeaderRow: View {
    let days: [Date]
    @Environment(CalendarStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            // Note: don't use Color.clear, it expands vertically and stretches the date bar
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
                    // Double-click a date to open day view
                    store.anchorDate = day
                    store.mode = .day
                }
            }
        }
    }
}

// MARK: - Time ruler

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
            // Scroll anchor: placed 12pt above the hour so the time label is fully visible after scrolling
            // (it must change layout position; offset only affects drawing and scrollTo ignores it)
            ForEach(0..<24, id: \.self) { hour in
                VStack(spacing: 0) {
                    Spacer().frame(height: max(CGFloat(hour) * CalendarMetrics.hourHeight - 12, 0))
                    // Use string ids: ForEach elements' own integer ids would also match scrollTo, so they must be distinguished
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

// MARK: - Grid lines

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
