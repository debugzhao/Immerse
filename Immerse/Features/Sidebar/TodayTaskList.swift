import SwiftUI

/// Sidebar "Today" task list: sorted by priority, then start time; click the circle to complete
struct TodayTaskList: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let tasks = todayTasks
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionHeader(
                title: "今天",
                trailing: "\(tasks.filter { $0.status == .done }.count)/\(tasks.count)"
            )
            if tasks.isEmpty {
                Text("今天没有安排，享受空白 🌿")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(tasks) { task in
                        TodayTaskRow(task: task, isSelected: store.selectedTaskID == task.id)
                            .onTapGesture {
                                store.anchorDate = .now
                                store.select(task.id)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { store.openEditor(task.id) })
                            .taskContextMenu(task)
                    }
                }
            }
        }
    }

    private var todayTasks: [TaskSnapshot] {
        let calendar = store.calendar
        guard let today = calendar.dateInterval(of: .day, for: .now) else { return [] }
        return taskStore.tasks(in: today).sorted { a, b in
            // Completed tasks sink to the bottom
            if (a.status == .done) != (b.status == .done) { return b.status == .done }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.start < b.start
        }
    }
}

private struct TodayTaskRow: View {
    let task: TaskSnapshot
    let isSelected: Bool

    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    private var isDone: Bool { task.status == .done }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Motion.snappy) { taskStore.toggleDone(task.id) }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : task.status == .inProgress ? "circle.dotted.circle" : "circle")
                    .foregroundStyle(task.priority.color)
                    .font(.system(size: 13))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(isDone ? "标记为未完成" : "标记完成")

            Text(task.displayTitle)
                .font(.system(size: 12))
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(timeLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        }
        .contentShape(Rectangle())
    }

    private var timeLabel: String {
        task.isAllDay ? "全天" : TimeText.hhmm(task.start, calendar: store.calendar)
    }
}
