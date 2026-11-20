import ImmerseAgent
import ImmerseCore
import SwiftUI

/// Size constants for the iPhone calendar
enum GridMetrics {
    static let hourHeight: CGFloat = 56
    static let gutterWidth: CGFloat = 44
    static let allDayLaneHeight: CGFloat = 22
    static let initialScrollHour = 8
    /// Shortest block: one snap step, so 15-minute events share one height and back-to-back ones stack
    static let minimumEventHeight: CGFloat = hourHeight / 4
    static var minimumEventDuration: TimeInterval { TimeInterval(minimumEventHeight / hourHeight * 3600) }
    static var gridHeight: CGFloat { hourHeight * 24 }

    static func y(for date: Date, dayStart: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourHeight
    }

    /// Time at a y position, snapped to the drag step and clamped to the day
    static func date(forY y: CGFloat, dayStart: Date) -> Date {
        let step = Double(EventEditing.snapMinutes)
        let minutes = (Double(y / hourHeight) * 60 / step).rounded(.down) * step
        return dayStart.addingTimeInterval(min(max(minutes, 0), 24 * 60 - step) * 60)
    }

    static func snappedMinutes(forDeltaY dy: CGFloat) -> Int {
        let step = Double(EventEditing.snapMinutes)
        return Int((Double(dy / hourHeight) * 60 / step).rounded() * step)
    }
}

/// The 日程 tab: header with mode switch, then the time grid (day / 3-day) or the month grid
struct ScheduleView: View {
    @Environment(ScheduleState.self) private var schedule
    @Environment(Secretary.self) private var secretary
    @Environment(EventKitCalendarSource.self) private var systemCalendar

    var body: some View {
        @Bindable var schedule = schedule
        NavigationStack {
            VStack(spacing: 0) {
                if let suggestion = schedule.suggestion {
                    SuggestionBanner(suggestion: suggestion).padding(.vertical, 6)
                }
                if schedule.mode == .month {
                    MonthGridView()
                } else {
                    DayHeaderRow(days: schedule.visibleDays)
                    AllDayRow(days: schedule.visibleDays)
                    Divider()
                    TimeGridView(days: schedule.visibleDays)
                }
            }
            .navigationTitle(schedule.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let proposal = secretary.activeProposal {
                    ProposalBar(proposal: proposal).transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if secretary.isWorking {
                    ProgressView("秘书正在安排…").padding().glassCard()
                }
            }
            .animation(Motion.snappy, value: secretary.activeProposal?.id)
            .animation(Motion.snappy, value: schedule.suggestion?.id)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今天") { withAnimation(Motion.snappy) { schedule.goToToday() } }
                }
                ToolbarItem(placement: .principal) {
                    Picker("视图", selection: $schedule.mode.animation(Motion.snappy)) {
                        ForEach(ScheduleMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 168)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SecretaryMenu()
                    Button { withAnimation(Motion.snappy) { schedule.step(-1) } } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("上一页")
                    Button { withAnimation(Motion.snappy) { schedule.step(1) } } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("下一页")
                }
            }
        }
    }
}

/// Weekday + date for each visible column; tapping a date in 3-day mode zooms into that day
struct DayHeaderRow: View {
    let days: [Date]
    @Environment(ScheduleState.self) private var schedule

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: GridMetrics.gutterWidth)
            ForEach(days, id: \.self) { day in
                let isToday = schedule.isToday(day)
                Button {
                    if schedule.mode == .threeDay { withAnimation(Motion.snappy) { schedule.show(day: day) } }
                } label: {
                    HStack(spacing: 4) {
                        Text(TimeText.weekday(day, calendar: schedule.calendar))
                            .font(.caption)
                            .foregroundStyle(isToday ? Palette.nowIndicator : .secondary)
                        Text("\(schedule.calendar.component(.day, from: day))")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(isToday ? .white : .primary)
                            .frame(minWidth: 26, minHeight: 26)
                            .background(isToday ? Palette.nowIndicator : .clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        // The gutter spacer is a Color, which would otherwise stretch to take a share of the screen's height
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The secretary's actions for the visible days
struct SecretaryMenu: View {
    @Environment(ScheduleState.self) private var schedule
    @Environment(Secretary.self) private var secretary
    @Environment(TaskStore.self) private var taskStore
    @Environment(EventKitCalendarSource.self) private var systemCalendar

    var body: some View {
        Menu {
            Button { schedule.isBriefingPresented = true } label: { Label("今日简报", systemImage: "sun.max") }
            Button { schedule.isReviewPresented = true } label: { Label("今天的复盘", systemImage: "moon.stars") }
            Divider()
            Button {
                Task { await planInbox() }
            } label: { Label("把收集箱排进本周", systemImage: "tray.and.arrow.down") }
            .disabled(taskStore.ideas().isEmpty)
            Button {
                if let proposal = secretary.reflow(from: .now) {
                    schedule.showProposal(proposal, secretary: secretary)
                } else {
                    taskStore.toast = Toast(message: "今天剩下的安排不需要调整")
                }
            } label: { Label("重排今天", systemImage: "arrow.uturn.forward") }
            Button {
                let today = Date.now
                if let proposal = secretary.overloadProposal(day: today) {
                    schedule.showProposal(proposal, secretary: secretary)
                } else {
                    let load = secretary.insights().today
                    taskStore.toast = Toast(message: "今天排了 \(DurationText.minutes(load.plannedMinutes * 60))，没有过载")
                }
            } label: { Label("检查今天是否过载", systemImage: "gauge.with.dots.needle.67percent") }
            if !systemCalendar.isAuthorized {
                Divider()
                Button {
                    Task { await systemCalendar.requestAccess() }
                } label: { Label("读取系统日历的会议", systemImage: "calendar.badge.clock") }
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .accessibilityLabel("秘书")
    }

    private func planInbox() async {
        if systemCalendar.isUndetermined { await systemCalendar.requestAccess() }
        let proposal = await secretary.planInbox()
        if let proposal {
            schedule.showProposal(proposal, secretary: secretary)
        } else if let notice = secretary.notice {
            taskStore.toast = Toast(message: notice)
            secretary.notice = nil
        }
    }
}
