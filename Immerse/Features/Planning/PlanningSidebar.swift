import SwiftUI

// MARK: - Inbox

/// Sidebar Inbox panel: ideas that aren't scheduled yet. Type to capture, drag a row onto the calendar to schedule it
struct InboxSection: View {
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        let ideas = taskStore.ideas()
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionHeader(title: "收集箱", trailing: "\(ideas.count)")
            VStack(spacing: 2) {
                QuickAddField(placeholder: "记个想法…", icon: "plus") { taskStore.captureIdea($0) }
                if ideas.isEmpty {
                    SidebarEmptyHint(text: "想到什么先记下来，有空再拖进日历")
                }
                ForEach(ideas) { IdeaRow(idea: $0) }
            }
        }
    }
}

private struct IdeaRow: View {
    let idea: TaskSnapshot
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        PlanningRow(isSelected: store.editingTaskID == idea.id) {
            Image(systemName: "lightbulb")
                .font(.system(size: 12))
                .foregroundStyle(idea.priority.color)
                .frame(width: 14)
            Text(idea.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .onTapGesture { store.openEditor(idea.id) }
        .draggable(idea.id.uuidString) { DragChip(title: idea.displayTitle, icon: "lightbulb") }
        .help("拖到日历上排期，点击查看详情")
        .contextMenu {
            Button("打开") { store.openEditor(idea.id) }
            Button("安排到今天下一个整点") { scheduleNextHour() }
            Divider()
            ForEach(GoalPeriod.allCases) { period in
                Button("设为\(period.title)目标") { taskStore.makeGoal(idea.id, period: period, calendar: store.calendar) }
            }
            Divider()
            Button("删除", role: .destructive) { taskStore.delete(id: idea.id) }
        }
    }

    private func scheduleNextHour() {
        let start = store.defaultNewEventInterval(now: .now).start
        if let event = taskStore.schedule(idea.id, at: start, calendar: store.calendar) {
            store.reveal(event)
        }
    }
}

// MARK: - Goals

/// Sidebar Goals panel: this week / this month, with progress. Drag a goal onto the calendar to book a session for it
struct GoalsSection: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @State private var period: GoalPeriod = .month

    var body: some View {
        let goals = Self.activeGoals(taskStore: taskStore, calendar: store.calendar)
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionHeader(
                title: "目标",
                trailing: "\(goals.filter { $0.status == .done }.count)/\(goals.count)"
            )
            VStack(spacing: 2) {
                QuickAddField(placeholder: "新的\(period.title)目标…", icon: "plus") {
                    taskStore.createGoal($0, period: period, calendar: store.calendar)
                } trailing: {
                    Button(period.title) {
                        period = period == .month ? .week : .month
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("切换新目标的周期：本周 / 本月")
                }

                if goals.isEmpty {
                    SidebarEmptyHint(text: "比如「这个月读完《纳瓦尔宝典》」，拖到日历上安排每次的时间")
                }
                ForEach(goals) { GoalRow(goal: $0) }
            }
        }
    }

    /// Goals whose period isn't over, unfinished first, then by end date (shared with the tab picker's count)
    @MainActor
    static func activeGoals(taskStore: TaskStore, calendar: Calendar) -> [TaskSnapshot] {
        taskStore.goals()
            .filter { $0.isActiveGoal(now: .now, calendar: calendar) }
            .sorted { a, b in
                if (a.status == .done) != (b.status == .done) { return b.status == .done }
                return a.displayInterval(in: calendar).end < b.displayInterval(in: calendar).end
            }
    }
}

private struct GoalRow: View {
    let goal: TaskSnapshot
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine

    var body: some View {
        let progress = goalProgress(goal, taskStore: taskStore, focusEngine: focusEngine, calendar: store.calendar)
        let isDone = goal.status == .done
        PlanningRow(isSelected: store.editingTaskID == goal.id) {
            ProgressRing(fraction: progress.fraction, color: isDone ? .green : goal.priority.color)
            Text(goal.displayTitle)
                .font(.system(size: 12))
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if progress.isBehind {
                    Text("落后").foregroundStyle(.orange)
                } else if !isDone {
                    Text(verbatim: "\(progress.daysLeft)天")
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .onTapGesture { store.openEditor(goal.id) }
        .draggable(goal.id.uuidString) { DragChip(title: goal.displayTitle, icon: "target") }
        .help("\(progress.percent)% · \(progress.summary)\(isDone ? "" : " · 还剩 \(progress.daysLeft) 天")\n拖到日历上安排一次时间，专注时长会计入这个目标")
        .contextMenu {
            Button("打开") { store.openEditor(goal.id) }
            if !isDone && !focusEngine.isFocusing(on: goal.id) {
                Button("开始专注 \(goal.focusMinutes) 分钟") { focusEngine.requestStart(goal) }
            }
            Button(isDone ? "标记为未完成" : "标记完成") { taskStore.toggleDone(goal.id) }
            Divider()
            Button("移回收集箱") { taskStore.moveToInbox(goal.id) }
            Button("删除", role: .destructive) { taskStore.delete(id: goal.id) }
        }
    }
}

/// Progress of a goal from the stores (shared by the sidebar, ribbon and editor)
@MainActor
func goalProgress(_ goal: TaskSnapshot, taskStore: TaskStore, focusEngine: FocusEngine, calendar: Calendar) -> GoalProgress {
    GoalProgress(goal: goal,
                 linkedEvents: taskStore.events(linkedTo: goal.id),
                 records: focusEngine.records(in: goal.displayInterval(in: calendar)),
                 now: .now, calendar: calendar)
}

// MARK: - Building blocks

/// Inline "type and press Return" row used by the Inbox and Goals panels.
/// Looks like a list row rather than a boxed input; a soft background appears only while typing
struct QuickAddField<Trailing: View>: View {
    let placeholder: String
    let icon: String
    let onSubmit: (String) -> Void
    @ViewBuilder var trailing: Trailing

    @State private var text = ""
    @FocusState private var isFocused: Bool

    init(placeholder: String, icon: String, onSubmit: @escaping (String) -> Void,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.placeholder = placeholder
        self.icon = icon
        self.onSubmit = onSubmit
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 14)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit {
                    onSubmit(text)
                    text = ""
                    // Keep focus so several ideas can be typed in a row
                    isFocused = true
                }
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .animation(Motion.snappy, value: isFocused)
    }
}

/// Row shell matching the Today list: same padding, same hover / selection background
private struct PlanningRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .sidebarRowBackground(isSelected: isSelected)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(geometry.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
        .animation(Motion.snappy, value: fraction)
    }
}

/// 14pt ring used by goal rows: the sidebar's single-line stand-in for a progress bar
struct ProgressRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            // Track tinted with the goal's color so the ring reads as colored even at 0%
            Circle().stroke(color.opacity(0.3), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(fraction, fraction > 0 ? 0.04 : 0))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .frame(width: 14)
        .animation(Motion.snappy, value: fraction)
    }
}

/// What follows the pointer while dragging an idea / goal
private struct DragChip: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
