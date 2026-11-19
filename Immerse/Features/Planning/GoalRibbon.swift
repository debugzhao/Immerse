import SwiftUI

/// Strip above the calendar: goals whose period overlaps what's on screen, with progress. Hidden when there are none
struct GoalRibbon: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine

    var body: some View {
        let visible = store.visibleInterval
        let goals = taskStore.goals().filter { $0.displayInterval(in: store.calendar).overlapsHalfOpen(visible) }
        if !goals.isEmpty {
            HStack(spacing: 8) {
                Label("目标", systemImage: "target")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(goals) { goal in
                            chip(goal)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.opacity)
        }
    }

    private func chip(_ goal: TaskSnapshot) -> some View {
        let progress = goalProgress(goal, taskStore: taskStore, focusEngine: focusEngine, calendar: store.calendar)
        let color = goal.status == .done ? Color.green : goal.priority.color
        return Button { store.openEditor(goal.id) } label: {
            HStack(spacing: 6) {
                Text(goal.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .strikethrough(goal.status == .done)
                    .lineLimit(1)
                ProgressBar(fraction: progress.fraction, color: color)
                    .frame(width: 36)
                Text(verbatim: "\(progress.percent)%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(progress.isBehind ? Color.orange : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .draggable(goal.id.uuidString) {
            Label(goal.displayTitle, systemImage: "target")
                .font(.system(size: 12, weight: .medium))
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .help("\(progress.summary) · 还剩 \(progress.daysLeft) 天。拖到日历上安排一次时间")
    }
}
