import Charts
import ImmerseCore
import SwiftUI

/// The 统计 tab: today / this week, streak, a 7-day chart and the most-focused tasks
struct StatsView: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(ScheduleState.self) private var schedule
    @State private var showsSettings = false

    var body: some View {
        let calendar = schedule.calendar
        let now = Date.now
        let start = calendar.date(byAdding: .day, value: -35, to: calendar.startOfDay(for: now)) ?? now
        let stats = FocusStats(records: focusEngine.records(in: DateInterval(start: start, end: now.addingTimeInterval(1))),
                               now: now, calendar: calendar)

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        tile("今日专注", DurationText.minutes(stats.todayMinutes * 60))
                        tile("本周专注", DurationText.minutes(stats.weekMinutes * 60))
                    }
                    HStack(spacing: 12) {
                        tile("本周完成", "\(stats.weekCompleted) 次")
                        tile("连续专注", "\(stats.streakDays) 天")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近 7 天").font(.headline)
                        Chart(stats.lastSevenDays) { day in
                            BarMark(x: .value("日期", TimeText.weekday(day.date, calendar: calendar)),
                                    y: .value("分钟", day.minutes))
                                .foregroundStyle(Palette.brand.gradient)
                                .cornerRadius(4)
                        }
                        .frame(height: 180)
                    }
                    .padding()
                    .glassCard()
                    if !stats.topTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("本周专注最多").font(.headline)
                            ForEach(stats.topTasks) { task in
                                HStack {
                                    Text(task.title).lineLimit(1)
                                    Spacer()
                                    Text("\(task.sessions) 次 · \(DurationText.minutes(task.minutes * 60))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                    }
                }
                .padding()
            }
            .navigationTitle("统计")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView() }
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
