import SwiftUI

/// "今日规划" sheet: the Inbox and lagging goals on the left, today's free time on the right.
/// "安排" books the item into the first free slot, so a morning's planning is a few clicks.
struct DailyPlanView: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Booked from this sheet, listed under the free slots so the effect is visible
    @State private var booked: [TaskSnapshot] = []

    private var calendar: Calendar { store.calendar }

    var body: some View {
        let now = Date.now
        let ideas = taskStore.ideas()
        let goals = GoalsSection.behindGoals(GoalsSection.activeGoals(taskStore: taskStore, calendar: calendar),
                                             taskStore: taskStore, focusEngine: focusEngine, calendar: calendar)
        let slots = freeSlots(now: now)

        VStack(alignment: .leading, spacing: 14) {
            header(now: now, ideas: ideas.count, goals: goals.count)

            HStack(alignment: .top, spacing: 20) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if ideas.isEmpty && goals.isEmpty {
                            SidebarEmptyHint(text: "收集箱是空的，目标进度也都正常。")
                        }
                        if !ideas.isEmpty {
                            group("收集箱") {
                                ForEach(ideas) { idea in
                                    row(idea, icon: "lightbulb", tint: idea.priority.color,
                                        pill: stalePill(idea, now: now), canBook: !slots.isEmpty) {
                                        book(idea, slots: slots)
                                    }
                                }
                            }
                        }
                        if !goals.isEmpty {
                            group("落后的目标") {
                                ForEach(goals) { goal in
                                    let progress = goalProgress(goal, taskStore: taskStore, focusEngine: focusEngine,
                                                                calendar: calendar)
                                    row(goal, icon: "target", tint: .orange,
                                        pill: AttentionPill(text: "\(progress.percent)% · 落后", color: .orange),
                                        canBook: !slots.isEmpty) {
                                        book(goal, slots: slots)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    group("今天的空闲时段") {
                        if slots.isEmpty {
                            SidebarEmptyHint(text: "今天已经没有 \(DailyPlan.minimumSlotMinutes) 分钟以上的空档了。")
                        }
                        ForEach(slots, id: \.start) { slot in
                            SlotRow(slot: slot, calendar: calendar)
                        }
                    }
                    if !booked.isEmpty {
                        group("刚刚安排") {
                            ForEach(booked) { event in
                                BookedRow(event: event, calendar: calendar)
                            }
                        }
                    }
                }
                .frame(width: 210, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 360)

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 640)
    }

    // MARK: - Pieces

    private func header(now: Date, ideas: Int, goals: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(greeting(now))，今天安排点什么？")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(now, format: .dateTime.month().day().weekday(.wide))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(summary(ideas: ideas, goals: goals))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("不再自动弹出", isOn: Binding(
                get: { !settings.dailyPlanEnabled },
                set: { settings.dailyPlanEnabled = !$0 }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .help("之后可以从菜单「显示 → 今日规划…」打开，或在设置里重新开启")
            Spacer()
            Button("今天先跳过") { dismiss() }
            Button("开始今天") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ task: TaskSnapshot, icon: String, tint: Color, pill: AttentionPill?,
                     canBook: Bool, book: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(task.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let pill { pill }
            if canBook {
                Button("安排", action: book)
                    .controlSize(.small)
                    .help("放进今天第一个空闲时段")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .sidebarRowBackground(isSelected: false)
    }

    private func stalePill(_ idea: TaskSnapshot, now: Date) -> AttentionPill? {
        let staleness = IdeaStaleness.of(idea, now: now, calendar: calendar)
        return staleness.days.map { AttentionPill(text: "搁置 \($0) 天", color: staleness.color) }
    }

    // MARK: - Logic

    private func freeSlots(now: Date) -> [DateInterval] {
        guard let today = calendar.dateInterval(of: .day, for: now) else { return [] }
        let busy = taskStore.tasks(in: today).filter { !$0.isAllDay }.map { $0.displayInterval(in: calendar) }
        return DailyPlan.freeSlots(busy: busy, day: now, now: now, calendar: calendar)
    }

    private func book(_ task: TaskSnapshot, slots: [DateInterval]) {
        guard let slot = slots.first else { return }
        withAnimation(Motion.snappy) {
            if let event = taskStore.schedule(task.id, at: slot.start, minutes: DailyPlan.sessionMinutes(in: slot),
                                              calendar: calendar) {
                booked.append(event)
            }
        }
    }

    private func greeting(_ now: Date) -> String {
        switch calendar.component(.hour, from: now) {
        case ..<12: "早上好"
        case ..<18: "下午好"
        default: "晚上好"
        }
    }

    private func summary(ideas: Int, goals: Int) -> String {
        var parts: [String] = []
        if ideas > 0 { parts.append("收集箱里有 \(ideas) 条想法") }
        if goals > 0 { parts.append("\(goals) 个目标进度落后") }
        guard !parts.isEmpty else { return "没有待安排的想法和目标。" }
        return parts.joined(separator: "，") + "。点「安排」放进今天的空闲时段。"
    }
}

private struct SlotRow: View {
    let slot: DateInterval
    let calendar: Calendar

    var body: some View {
        HStack {
            Text(TimeText.range(slot.start, slot.end, calendar: calendar))
                .monospacedDigit()
            Spacer()
            Text(DurationText.minutes(Int(slot.duration)))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
        }
    }
}

private struct BookedRow: View {
    let event: TaskSnapshot
    let calendar: Calendar

    var body: some View {
        let interval = event.displayInterval(in: calendar)
        HStack(spacing: 0) {
            Rectangle().fill(event.priority.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(TimeText.range(interval.start, interval.end, calendar: calendar))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .background(event.priority.color.opacity(0.14))
    }
}
