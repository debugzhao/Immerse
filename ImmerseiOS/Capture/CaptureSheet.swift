import ImmerseCore
import SwiftUI

/// The "+" sheet: type one sentence, see it parsed live, then add it to the calendar or drop it in the Inbox.
/// 「想法：…」 goes straight to the Inbox and 「本月目标：…」 creates a goal, same as ⌘K on the Mac.
struct CaptureSheet: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(ScheduleState.self) private var schedule
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: ParsedInput { NaturalLanguageParser.parse(trimmed, now: .now, calendar: schedule.calendar) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("明天下午3点 阅读 1小时 重要", text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(addToCalendar)
                    .padding(14)
                    .glassCard(cornerRadius: 14)

                if !trimmed.isEmpty {
                    CapturePreview(kind: kind, parsed: parsed, calendar: schedule.calendar)
                        .transition(.opacity)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button(action: addToInbox) {
                        Label("放进收集箱", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(action: addToCalendar) {
                        Label(kind == .goal ? "创建目标" : "添加到日程", systemImage: kind == .goal ? "target" : "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brand)
                }
                .controlSize(.large)
                .disabled(trimmed.isEmpty)
            }
            .padding()
            .navigationTitle("收集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .animation(Motion.snappy, value: trimmed.isEmpty)
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    enum Kind { case event, idea, goal }

    private var kind: Kind {
        if PlanningInput.goal(from: trimmed) != nil { return .goal }
        if PlanningInput.isExplicitIdea(trimmed) { return .idea }
        return .event
    }

    private func addToInbox() {
        let title = PlanningInput.isExplicitIdea(trimmed) ? PlanningInput.idea(from: trimmed) : trimmed
        guard taskStore.captureIdea(title) != nil else { return }
        taskStore.toast = Toast(message: "已放进收集箱", showsUndo: true)
        Haptics.success()
        dismiss()
    }

    private func addToCalendar() {
        guard !trimmed.isEmpty else { return }
        switch kind {
        case .goal:
            if let goal = PlanningInput.goal(from: trimmed) {
                _ = taskStore.createGoal(goal.title, period: goal.period, calendar: schedule.calendar)
                taskStore.toast = Toast(message: "已创建\(goal.period.title)目标", showsUndo: true)
            }
        case .idea:
            addToInbox()
            return
        case .event:
            var snapshot = parsed.makeSnapshot(now: .now, calendar: schedule.calendar)
            snapshot.source = .manual
            let created = taskStore.create(snapshot)
            schedule.anchorDate = schedule.calendar.startOfDay(for: created.start)
            taskStore.toast = Toast(message: "已添加「\(created.displayTitle)」", showsUndo: true)
        }
        Haptics.success()
        dismiss()
    }
}

/// What the sentence turned into: title, time, duration, priority, place
struct CapturePreview: View {
    let kind: CaptureSheet.Kind
    let parsed: ParsedInput
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch kind {
            case .goal:
                Label("将创建一个目标", systemImage: "target").foregroundStyle(.secondary)
            case .idea:
                Label("将放进收集箱，稍后再排期", systemImage: "lightbulb").foregroundStyle(.secondary)
            case .event:
                Text(parsed.title.isEmpty ? "（无标题）" : parsed.title)
                    .font(.headline)
                FlowChips(chips: chips)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: [(String, String)] {
        var result: [(String, String)] = []
        let snapshot = parsed.makeSnapshot(now: .now, calendar: calendar)
        if snapshot.isAllDay {
            result.append(("calendar", "\(TimeText.weekday(snapshot.start, calendar: calendar)) 全天"))
        } else {
            result.append(("clock", "\(TimeText.weekday(snapshot.start, calendar: calendar)) \(TimeText.hhmm(snapshot.start, calendar: calendar))"))
        }
        if let minutes = parsed.durationMinutes { result.append(("timer", DurationText.minutes(minutes * 60))) }
        if let priority = parsed.priority { result.append(("flag", priority.title)) }
        if let place = parsed.place { result.append(("mappin", place)) }
        return result
    }
}

/// Small rounded labels that wrap onto new lines
struct FlowChips: View {
    let chips: [(String, String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
            Label(chip.1, systemImage: chip.0)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }
}
