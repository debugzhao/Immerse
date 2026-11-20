import ActivityKit
import AppIntents
import ImmerseCore
import SwiftUI
import WidgetKit

@main
struct ImmerseWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        FocusLiveActivity()
    }
}

// MARK: - 今天

struct TodayEntry: TimelineEntry {
    let date: Date
    let tasks: [TaskSnapshot]
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, tasks: [
            TaskSnapshot(title: "写方案", start: .now, end: .now.addingTimeInterval(3600), isAllDay: false, priority: .urgent),
            TaskSnapshot(title: "回复邮件", start: .now.addingTimeInterval(7200), isAllDay: false),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        Task { @MainActor in completion(TodayEntry(date: .now, tasks: SharedStore.todayTasks())) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        Task { @MainActor in
            let entry = TodayEntry(date: .now, tasks: SharedStore.todayTasks())
            // Refresh at the next half hour; the app also reloads timelines whenever tasks change
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今天")
        .description("今天还没完成的任务，可以直接勾选完成或开始专注")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family

    private var limit: Int {
        switch family {
        case .systemSmall: 3
        case .systemLarge: 8
        default: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今天").font(.headline)
                Spacer()
                Text(entry.tasks.isEmpty ? "全部完成" : "\(entry.tasks.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if entry.tasks.isEmpty {
                Spacer()
                Label("今天的任务都做完了", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.tasks.prefix(limit)) { task in
                    row(task)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ task: TaskSnapshot) -> some View {
        HStack(spacing: 6) {
            Button(intent: CompleteTaskIntent(task: TaskEntity(task))) {
                Image(systemName: "circle").foregroundStyle(color(task.priority))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完成 \(task.displayTitle)")
            VStack(alignment: .leading, spacing: 0) {
                Text(task.displayTitle).font(.caption.weight(.medium)).lineLimit(1)
                if family != .systemSmall {
                    Text(task.isAllDay ? "全天" : TimeText.hhmm(task.start)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if family != .systemSmall && !task.isAllDay {
                Button(intent: StartFocusIntent(task: TaskEntity(task))) {
                    Image(systemName: "play.circle.fill").foregroundStyle(Color.indigo)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("开始专注 \(task.displayTitle)")
            }
        }
    }

    private func color(_ priority: Priority) -> Color {
        switch priority {
        case .urgent: .red
        case .important: .orange
        case .normal: .purple
        }
    }
}

// MARK: - Live Activity

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            LockScreenFocusView(title: context.attributes.taskTitle, state: context.state)
                .padding()
                .activityBackgroundTint(Color.indigo.opacity(0.25))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.isPaused ? "已暂停" : "专注中", systemImage: "timer").font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: context.state).font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.taskTitle).font(.headline).lineLimit(1)
                        FocusButtons(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "timer").foregroundStyle(.indigo)
            } compactTrailing: {
                CountdownText(state: context.state).frame(maxWidth: 52).monospacedDigit()
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.indigo)
            }
        }
    }
}

struct LockScreenFocusView: View {
    let title: String
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.isTimeUp ? "时间到" : state.isPaused ? "已暂停" : "专注中", systemImage: "timer")
                    .font(.caption.weight(.semibold))
                Spacer()
                CountdownText(state: state).font(.title2.weight(.light).monospacedDigit())
            }
            Text(title).font(.headline).lineLimit(1)
            if state.isPaused || state.isTimeUp {
                ProgressView(value: state.progress(at: .now))
            } else {
                ProgressView(timerInterval: state.startedAt...max(state.endDate, state.startedAt), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            }
            FocusButtons(state: state)
        }
        .tint(.indigo)
    }
}

/// Counts down by itself from `endDate`; frozen while paused
struct CountdownText: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        if state.isTimeUp {
            Text("00:00")
        } else if let remaining = state.pausedRemaining {
            Text(Duration.seconds(remaining), format: .time(pattern: remaining >= 3600 ? .hourMinuteSecond : .minuteSecond))
        } else {
            Text(timerInterval: Date.now...max(state.endDate, .now), countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct FocusButtons: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if !state.isTimeUp {
                Button(intent: ToggleFocusPauseIntent()) {
                    Label(state.isPaused ? "继续" : "暂停", systemImage: state.isPaused ? "play.fill" : "pause.fill")
                }
            }
            Button(intent: FinishFocusIntent()) {
                Label("完成", systemImage: "checkmark")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
    }
}
