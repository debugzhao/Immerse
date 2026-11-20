import ImmerseCore
import SwiftUI

/// The 规划 tab: the Inbox (ideas without a time yet) and this week's / month's goals
struct PlanningView: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(ScheduleState.self) private var schedule

    @State private var newIdea = ""
    @State private var newGoal = ""
    @State private var newGoalPeriod: GoalPeriod = .week

    private var calendar: Calendar { schedule.calendar }

    var body: some View {
        NavigationStack {
            List {
                inboxSection
                goalsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("规划")
        }
    }

    // MARK: - Inbox

    private var inboxSection: some View {
        Section {
            HStack {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("记个想法…", text: $newIdea)
                    .submitLabel(.done)
                    .onSubmit {
                        if taskStore.captureIdea(newIdea) != nil {
                            newIdea = ""
                            Haptics.success()
                        }
                    }
            }
            ForEach(taskStore.ideas()) { idea in
                IdeaRow(idea: idea, calendar: calendar)
                    .contentShape(Rectangle())
                    .onTapGesture { schedule.editor = .existing(idea.id) }
                    .swipeActions(edge: .leading) {
                        Button { scheduleSoon(idea) } label: { Label("安排", systemImage: "calendar.badge.plus") }
                            .tint(Palette.brand)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { taskStore.delete(id: idea.id) } label: { Label("删除", systemImage: "trash") }
                    }
            }
        } header: {
            Text("收集箱")
        } footer: {
            Text("向右滑动「安排」会放进今天或明天最早的空档")
        }
    }

    /// Books an idea into the earliest free slot today (or tomorrow if today is full)
    private func scheduleSoon(_ idea: TaskSnapshot) {
        let now = Date.now
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let busy = taskStore.tasks(in: DateInterval(start: day, end: dayEnd))
                .filter { !$0.isAllDay && $0.status != .done }
                .map { $0.displayInterval(in: calendar) }
            if let slot = DailyPlan.freeSlots(busy: busy, day: day, now: now, calendar: calendar).first {
                let minutes = min(idea.plannedMinutes ?? DailyPlan.sessionMinutes, DailyPlan.sessionMinutes(in: slot))
                if let event = taskStore.schedule(idea.id, at: slot.start, minutes: minutes, calendar: calendar) {
                    taskStore.toast = Toast(message: "已安排到\(offset == 0 ? "今天" : "明天") \(TimeText.hhmm(event.start, calendar: calendar))",
                                            showsUndo: true)
                    Haptics.success()
                }
                return
            }
        }
        taskStore.toast = Toast(message: "今明两天都排满了，打开日程手动安排吧")
        Haptics.warning()
    }

    // MARK: - Goals

    private var goalsSection: some View {
        Section("目标") {
            HStack {
                Image(systemName: "target").foregroundStyle(.secondary)
                TextField("新的目标…", text: $newGoal)
                    .submitLabel(.done)
                    .onSubmit {
                        if taskStore.createGoal(newGoal, period: newGoalPeriod, calendar: calendar) != nil {
                            newGoal = ""
                            Haptics.success()
                        }
                    }
                Picker("周期", selection: $newGoalPeriod) {
                    ForEach(GoalPeriod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            ForEach(GoalQueries.active(taskStore: taskStore, calendar: calendar)) { goal in
                GoalRow(goal: goal,
                        progress: GoalQueries.progress(of: goal, taskStore: taskStore, focusEngine: focusEngine, calendar: calendar))
                    .contentShape(Rectangle())
                    .onTapGesture { schedule.editor = .existing(goal.id) }
                    .swipeActions(edge: .leading) {
                        Button { taskStore.toggleDone(goal.id) } label: {
                            Label(goal.status == .done ? "恢复" : "完成", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { taskStore.delete(id: goal.id) } label: { Label("删除", systemImage: "trash") }
                    }
            }
        }
    }
}

struct IdeaRow: View {
    let idea: TaskSnapshot
    let calendar: Calendar

    var body: some View {
        let staleness = IdeaStaleness.of(idea, now: .now, calendar: calendar)
        HStack {
            Image(systemName: "lightbulb").foregroundStyle(Palette.brand)
            Text(idea.displayTitle)
            Spacer()
            if let days = staleness.days {
                Text("搁置 \(days) 天")
                    .font(.caption)
                    .foregroundStyle(staleness.color)
            }
        }
    }
}

struct GoalRow: View {
    let goal: TaskSnapshot
    let progress: GoalProgress

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(fraction: progress.fraction, color: progress.isBehind ? .orange : Palette.brand)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.displayTitle)
                    .strikethrough(goal.status == .done)
                Text(progress.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if progress.isBehind {
                Text("落后").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else {
                Text("\(progress.daysLeft) 天").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(Motion.gentle, value: fraction)
    }
}
