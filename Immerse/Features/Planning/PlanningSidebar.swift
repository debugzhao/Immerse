import SwiftUI

// MARK: - Inbox

/// Sidebar Inbox: ideas that aren't scheduled yet. Type to capture, drag a row onto the calendar to schedule it
struct InboxSection: View {
    @Environment(TaskStore.self) private var taskStore
    @State private var isExpanded = false

    private static let collapsedLimit = 5

    var body: some View {
        let ideas = taskStore.ideas()
        VStack(alignment: .leading, spacing: 6) {
            SidebarSectionHeader(title: "收集箱", trailing: ideas.isEmpty ? nil : "\(ideas.count)")
            QuickAddField(placeholder: "记个想法…", icon: "plus") { taskStore.captureIdea($0) }

            if ideas.isEmpty {
                Text("想到什么先记下来，有空再拖进日历")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(isExpanded ? ideas : Array(ideas.prefix(Self.collapsedLimit))) { idea in
                        IdeaRow(idea: idea)
                    }
                }
                if ideas.count > Self.collapsedLimit {
                    Button(isExpanded ? "收起" : "展开全部 \(ideas.count) 条") {
                        withAnimation(Motion.snappy) { isExpanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                }
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
                .font(.system(size: 11))
                .foregroundStyle(idea.priority == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(idea.priority.color))
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

/// Sidebar goals: this week / this month, with progress. Drag a goal onto the calendar to book a session for it
struct GoalsSection: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @State private var period: GoalPeriod = .month

    var body: some View {
        let goals = activeGoals
        VStack(alignment: .leading, spacing: 6) {
            SidebarSectionHeader(title: "目标")
            QuickAddField(placeholder: "新的\(period.title)目标…", icon: "target") {
                taskStore.createGoal($0, period: period, calendar: store.calendar)
            } trailing: {
                Button(period.title) {
                    period = period == .month ? .week : .month
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .help("切换新目标的周期：本周 / 本月")
            }

            if goals.isEmpty {
                Text("比如「这个月读完《纳瓦尔宝典》」，拖到日历上安排每次的时间")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(goals) { goal in
                        GoalRow(goal: goal)
                    }
                }
            }
        }
    }

    /// Goals whose period isn't over, unfinished first, then by end date
    private var activeGoals: [TaskSnapshot] {
        let calendar = store.calendar
        return taskStore.goals()
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(goal.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(progress.percent)%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressBar(fraction: progress.fraction, color: isDone ? .green : goal.priority.color)
                HStack(spacing: 4) {
                    Text(progress.summary)
                    Spacer(minLength: 0)
                    if progress.isBehind {
                        Text("进度落后").foregroundStyle(.orange)
                    } else if !isDone {
                        Text("还剩 \(progress.daysLeft) 天")
                    }
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            }
        }
        .onTapGesture { store.openEditor(goal.id) }
        .draggable(goal.id.uuidString) { DragChip(title: goal.displayTitle, icon: "target") }
        .help("拖到日历上安排一次时间，专注时长会计入这个目标")
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

/// Inline "type and press Return" field used by the Inbox and Goals sections
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
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
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1, dash: isFocused ? [] : [3, 3]))
        )
    }
}

/// Row shell with hover / selection background
private struct PlanningRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
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
