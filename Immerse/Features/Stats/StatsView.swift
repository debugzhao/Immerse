import Charts
import SwiftUI

/// Focus stats window: today / this week overview, last-7-days bar chart, most-focused tasks this week
struct StatsView: View {
    @Environment(FocusEngine.self) private var engine
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let stats = currentStats
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    card("今日专注", DurationText.minutes(stats.todayMinutes * 60), "sun.max.fill", .orange)
                    card("本周专注", DurationText.minutes(stats.weekMinutes * 60), "calendar", .accentColor)
                    card("本周完成", "\(stats.weekCompleted)/\(stats.weekSessions) 次", "checkmark.seal.fill", .green)
                    card("连续专注", "\(stats.streakDays) 天", "flame.fill", .red)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("最近 7 天").font(.system(size: 13, weight: .semibold))
                    Chart(stats.lastSevenDays) { day in
                        BarMark(
                            x: .value("日期", day.date, unit: .day),
                            y: .value("分钟", day.minutes)
                        )
                        .foregroundStyle(store.calendar.isDateInToday(day.date) ? Color.accentColor : Color.accentColor.opacity(0.45))
                        .cornerRadius(4)
                        .annotation(position: .top) {
                            if day.minutes > 0 {
                                Text(verbatim: "\(day.minutes)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(TimeText.weekday(date, calendar: store.calendar))
                                }
                            }
                        }
                    }
                    .chartYAxisLabel("分钟")
                    .frame(height: 200)
                }
                .padding(16)
                .glassSurface(.panel)

                VStack(alignment: .leading, spacing: 10) {
                    Text("本周专注最多").font(.system(size: 13, weight: .semibold))
                    if stats.topTasks.isEmpty {
                        Text("本周还没有专注记录，选一个任务按 Space 开始吧")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(stats.topTasks) { task in
                        HStack {
                            Text(task.title).lineLimit(1)
                            Spacer()
                            Text(verbatim: "\(task.sessions) 次 · \(DurationText.minutes(task.minutes * 60))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        ProgressView(value: Double(task.minutes),
                                     total: Double(max(stats.topTasks.first?.minutes ?? 1, 1)))
                            .tint(.accentColor)
                    }
                }
                .padding(16)
                .glassSurface(.panel)
            }
            .padding(24)
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(VisualEffectBackground(material: .underWindowBackground))
    }

    private var currentStats: FocusStats {
        let calendar = store.calendar
        let today = calendar.startOfDay(for: .now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? today
        // Look back at most 60 days when counting the streak
        let from = min(calendar.date(byAdding: .day, value: -60, to: today) ?? today, weekStart)
        let to = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return FocusStats(records: engine.records(in: DateInterval(start: from, end: to)), now: .now, calendar: calendar)
    }

    private func card(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(.panel)
    }
}

/// Focus summary in the sidebar; click to open the stats window
struct FocusSummaryView: View {
    @Environment(FocusEngine.self) private var engine
    @Environment(CalendarStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let calendar = store.calendar
        let today = calendar.dateInterval(of: .day, for: .now) ?? DateInterval()
        let stats = FocusStats(records: engine.records(in: DateInterval(start: calendar.date(byAdding: .day, value: -7, to: today.start) ?? today.start, end: today.end)),
                               now: .now, calendar: calendar)
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionHeader(title: "专注")
            Button {
                openWindow(id: "stats")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "今日 \(DurationText.minutes(stats.todayMinutes * 60))")
                            .font(.system(size: 12, weight: .medium))
                        Text(verbatim: "本周 \(DurationText.minutes(stats.weekMinutes * 60)) · 连续 \(stats.streakDays) 天")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看专注统计")
        }
    }
}
