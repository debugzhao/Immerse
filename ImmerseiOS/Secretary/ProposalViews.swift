import ImmerseAgent
import ImmerseCore
import SwiftUI

/// Bottom bar while a proposal is shown: summary, warnings, one chip per item (tap to include / leave out),
/// and 取消 / 应用. Nothing is written until 应用, and the whole proposal undoes in one step.
struct ProposalBar: View {
    let proposal: PlanProposal
    @Environment(Secretary.self) private var secretary
    @Environment(TaskStore.self) private var taskStore
    @Environment(ScheduleState.self) private var schedule

    var body: some View {
        let previews = proposal.previewTasks { taskStore.task(id: $0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "sparkles").foregroundStyle(Palette.brand)
                Text(proposal.summary).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            ForEach(proposal.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(proposal.items) { item in
                        let task = previews.first { $0.item.id == item.id }?.task ?? taskStore.task(id: item.operation.taskID)
                        ProposalChip(item: item, task: task, calendar: schedule.calendar)
                            .onTapGesture {
                                Haptics.step()
                                secretary.toggle(item.id)
                            }
                    }
                }
            }
            HStack {
                Button("取消") {
                    withAnimation(Motion.snappy) { secretary.discardActiveProposal() }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    withAnimation(Motion.snappy) { _ = secretary.applyActiveProposal() }
                    Haptics.success()
                } label: {
                    Text("应用 \(proposal.selectedItems.count) 项").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brand)
                .disabled(proposal.selectedItems.isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// One proposed change: what, when, and why
struct ProposalChip: View {
    let item: PlanProposal.Item
    let task: TaskSnapshot?
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isSelected ? Palette.brand : .secondary)
                Text(task?.displayTitle ?? "任务").font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(when).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            Text(item.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(width: 160, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(item.isSelected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 10))
        .opacity(item.isSelected ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var when: String {
        if case .toInbox = item.operation { return "放回收集箱" }
        guard let task else { return "" }
        if task.kind == .idea { return "加入收集箱" }
        return "\(TimeText.weekday(task.start, calendar: calendar)) \(TimeText.hhmm(task.start, calendar: calendar))"
    }
}

/// A dashed "ghost" block for a proposed event, with its reason underneath when there's room
struct GhostBlock: View {
    let task: TaskSnapshot
    let reason: String
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            Text(task.displayTitle)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(height < 40 ? 1 : 2)
            if height >= 44 {
                Text(reason).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.brand.opacity(isSelected ? 0.12 : 0.04), in: shape)
        .overlay {
            shape.strokeBorder(Palette.brand.opacity(isSelected ? 1 : 0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        }
        .opacity(isSelected ? 1 : 0.6)
        .allowsHitTesting(false)
    }
}

/// A system-calendar meeting: gray, read-only
struct ExternalEventBlock: View {
    let event: ExternalEvent
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 0) {
            Rectangle().fill(Color.gray.opacity(0.6)).frame(width: 3)
            Text(event.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(max(1, Int(height / 14)))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.gray.opacity(0.12), in: shape)
        .clipShape(shape)
        .accessibilityLabel("系统日历：\(event.title)")
    }
}

/// "放弃了「X」，后面的安排要顺延吗？ [看看怎么排]" — a suggestion, never an automatic change
struct SuggestionBanner: View {
    let suggestion: Suggestion
    @Environment(ScheduleState.self) private var schedule
    @Environment(Secretary.self) private var secretary
    @State private var isWorking = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Palette.brand)
            Text(suggestion.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                isWorking = true
                Task {
                    let proposal = await suggestion.makeProposal()
                    isWorking = false
                    schedule.suggestion = nil
                    if let proposal { schedule.showProposal(proposal, secretary: secretary) }
                }
            } label: {
                if isWorking { ProgressView() } else { Text(suggestion.actionTitle).font(.subheadline.weight(.semibold)) }
            }
            .disabled(isWorking)
            Button {
                withAnimation(Motion.snappy) { schedule.suggestion = nil }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .accessibilityLabel("忽略")
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Before a session starts: where you left off, what's still open in the notes, how long this kind of task really takes
struct FocusBriefingSheet: View {
    let task: TaskSnapshot
    @Environment(Secretary.self) private var secretary
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(ScheduleState.self) private var schedule
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int

    init(task: TaskSnapshot) {
        self.task = task
        _minutes = State(initialValue: task.focusMinutes)
    }

    var body: some View {
        let briefing = secretary.focusBriefing(for: task)
        NavigationStack {
            List {
                if let last = briefing.lastSession {
                    Section("上次") {
                        Label("\(TimeText.weekday(last.startedAt, calendar: schedule.calendar)) 专注了 \(DurationText.minutes(last.focusedSeconds))，\(last.reason.title)",
                              systemImage: "clock.arrow.circlepath")
                    }
                }
                if !briefing.openTodos.isEmpty {
                    Section("备注里还有 \(briefing.openTodos.count) 个待办") {
                        ForEach(briefing.openTodos, id: \.self) { Label($0, systemImage: "circle") }
                    }
                }
                if let note = briefing.estimateNote {
                    Section {
                        Label(note, systemImage: "lightbulb")
                        Stepper("专注 \(DurationText.minutes(minutes * 60))", value: $minutes, in: 10...240, step: 15)
                    }
                }
            }
            .navigationTitle(task.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    var adjusted = task
                    adjusted.plannedMinutes = minutes
                    focusEngine.requestStart(adjusted)
                    schedule.selectedTab = .focus
                    Haptics.pickUp()
                    dismiss()
                } label: {
                    Label("开始专注 \(DurationText.minutes(minutes * 60))", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brand)
                .controlSize(.large)
                .padding()
            }
        }
        .presentationDetents([.medium])
    }
}

extension FocusEndReason {
    var title: String {
        switch self {
        case .completed: "按时完成"
        case .finishedEarly: "提前结束"
        case .abandoned: "中途放弃"
        case .closed: "到点未完成"
        }
    }
}

/// Starts focus on a task, showing the briefing first when there is something worth knowing
@MainActor
func startFocusWithBriefing(_ task: TaskSnapshot, secretary: Secretary, schedule: ScheduleState, focusEngine: FocusEngine) {
    if secretary.focusBriefing(for: task).isEmpty {
        focusEngine.requestStart(task)
        schedule.selectedTab = .focus
        Haptics.pickUp()
    } else {
        schedule.briefingTask = task
    }
}
