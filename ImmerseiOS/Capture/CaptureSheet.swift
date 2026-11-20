import ImmerseAgent
import ImmerseCore
import SwiftUI

/// The "+" sheet. Type, say or paste one sentence:
/// - plain sentence → parsed into tasks (by the AI when it's on, by rules otherwise), confirm, add
/// - 「记住……」 → a memory to confirm
/// - a request (「这周帮我找 2 小时写方案」) → the secretary plans it and shows a proposal on the calendar
struct CaptureSheet: View {
    @Environment(TaskStore.self) private var taskStore
    @Environment(NotificationService.self) private var notifications
    @Environment(ScheduleState.self) private var schedule
    @Environment(Secretary.self) private var secretary
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var source: TaskSource = .manual
    @State private var pastedURL: URL?
    @State private var stage: Stage = .editing
    @State private var voice = VoiceRecognizer()
    @FocusState private var isFocused: Bool

    enum Stage {
        case editing
        case working
        case drafts([CaptureDraft], usedAI: Bool)
        case memory(MemorySnapshot)
        case reply(String)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: ParsedInput { NaturalLanguageParser.parse(trimmed, now: .now, calendar: schedule.calendar) }
    private var isMemory: Bool { trimmed.hasPrefix("记住") }
    private var isRequest: Bool {
        let verbs = ["帮我", "安排", "排一下", "排进", "找时间", "找个时间", "挪", "重排", "空出"]
        return !isMemory && verbs.contains { trimmed.contains($0) } && !PlanningInput.isExplicitIdea(trimmed)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                inputField
                inputTools
                switch stage {
                case .editing:
                    if !trimmed.isEmpty { livePreview.transition(.opacity) }
                case .working:
                    HStack { ProgressView(); Text(secretary.ai.isAvailable ? "秘书正在整理…" : "整理中…") }
                        .foregroundStyle(.secondary)
                case .drafts(let drafts, let usedAI):
                    DraftList(drafts: drafts, usedAI: usedAI, calendar: schedule.calendar)
                case .memory(let memory):
                    MemoryCard(memory: memory)
                case .reply(let reply):
                    Label(reply, systemImage: "sparkles").font(.subheadline)
                }
                Spacer(minLength: 0)
                actions
            }
            .padding()
            .navigationTitle("收集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .animation(Motion.snappy, value: trimmed.isEmpty)
            .onAppear { isFocused = true }
            .onChange(of: voice.transcript) { _, transcript in
                if voice.isListening, !transcript.isEmpty {
                    text = transcript
                    source = .voice
                }
            }
            .onChange(of: text) { stage = .editing }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Input

    private var inputField: some View {
        TextField(voice.isListening ? "正在听…" : "明天下午3点 阅读 1小时 重要", text: $text, axis: .vertical)
            .font(.title3)
            .lineLimit(1...5)
            .focused($isFocused)
            .submitLabel(.done)
            .onSubmit { Task { await primaryAction() } }
            .padding(14)
            .glassCard(cornerRadius: 14)
            .overlay(alignment: .trailing) {
                if voice.isListening {
                    Circle().fill(.red).frame(width: 10, height: 10).padding(.trailing, 14)
                        .accessibilityLabel("正在录音")
                }
            }
    }

    private var inputTools: some View {
        HStack(spacing: 12) {
            // Press and hold to talk; release to stop
            Label(voice.isListening ? "松开结束" : "按住说话", systemImage: voice.isListening ? "waveform" : "mic.fill")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((voice.isListening ? Color.red : Palette.brand).opacity(0.14), in: Capsule())
                .foregroundStyle(voice.isListening ? .red : Palette.brand)
                .onLongPressGesture(minimumDuration: 0.05, maximumDistance: 80) {} onPressingChanged: { pressing in
                    if pressing {
                        Haptics.pickUp()
                        Task { await voice.start() }
                    } else {
                        voice.stop()
                    }
                }
                .accessibilityLabel("按住说话")
                .accessibilityAddTraits(.isButton)

            // The system paste button reads the clipboard without the "allow paste" prompt
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in await paste(strings.first ?? "") }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .tint(Palette.brand)

            Spacer()
        }
        .overlay(alignment: .bottomLeading) {
            if case .denied(let message) = voice.state {
                Text(message).font(.caption).foregroundStyle(.red).offset(y: 22)
            }
        }
    }

    private var livePreview: some View {
        Group {
            if isMemory {
                Label("秘书会记住这件事，排期时考虑进去", systemImage: "brain").foregroundStyle(.secondary)
            } else if isRequest && secretary.ai.isAvailable {
                Label("交给秘书安排，确认后才会改日历", systemImage: "sparkles").foregroundStyle(.secondary)
            } else {
                CapturePreview(kind: kind, parsed: parsed, calendar: schedule.calendar)
            }
        }
        .font(.subheadline)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 12) {
            switch stage {
            case .drafts(let drafts, _):
                Button("返回修改") { stage = .editing }.buttonStyle(.bordered)
                Button {
                    add(drafts)
                } label: {
                    Text(drafts.count > 1 ? "添加 \(drafts.count) 项" : "添加").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .memory(let memory):
                Button("返回修改") { stage = .editing }.buttonStyle(.bordered)
                Button {
                    secretary.saveMemory(memory)
                    taskStore.toast = Toast(message: "记住了：\(memory.text)")
                    Haptics.success()
                    dismiss()
                } label: { Text("记住").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            default:
                Button(action: addToInbox) {
                    Label("放进收集箱", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isMemory)
                Button {
                    Task { await primaryAction() }
                } label: {
                    Label(primaryTitle, systemImage: secretary.ai.isAvailable ? "sparkles" : "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .tint(Palette.brand)
        .controlSize(.large)
        .disabled(trimmed.isEmpty || isWorking)
    }

    private var isWorking: Bool { if case .working = stage { true } else { false } }

    private var primaryTitle: String {
        if isMemory { return "记住" }
        if isRequest && secretary.ai.isAvailable { return "交给秘书" }
        return secretary.ai.isAvailable ? "智能整理" : (kind == .goal ? "创建目标" : "添加到日程")
    }

    private func primaryAction() async {
        guard !trimmed.isEmpty, !isWorking else { return }
        voice.stop()
        if isMemory {
            stage = .working
            stage = .memory(await secretary.parseMemory(trimmed))
            return
        }
        if isRequest && secretary.ai.isAvailable {
            stage = .working
            let result = await secretary.ask(trimmed)
            if let proposal = result.proposal {
                dismiss()
                schedule.showProposal(proposal, secretary: secretary)
            } else {
                stage = .reply(result.reply ?? secretary.notice ?? "这件事没有需要改动的安排")
                secretary.notice = nil
            }
            return
        }
        guard secretary.ai.isAvailable else {
            // Rules only: one item, added straight away (the familiar ⌘K behavior)
            add([StructuredCalls.ruleCapture(trimmed, now: .now, calendar: schedule.calendar)])
            return
        }
        stage = .working
        let result = await secretary.capture(trimmed)
        if let notice = secretary.notice {
            taskStore.toast = Toast(message: notice)
            secretary.notice = nil
        }
        stage = .drafts(result.drafts, usedAI: result.usedAI)
    }

    private func paste(_ string: String) async {
        schedule.dismissClipboardHint()
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        source = .clipboard
        if let url = LinkTitleResolver.webURL(from: value) {
            pastedURL = url
            text = LinkTitleResolver.provisionalTitle(for: url)
            if let title = await LinkTitleResolver.fetchTitle(for: url), text == LinkTitleResolver.provisionalTitle(for: url) {
                text = title
            }
        } else {
            text = value
        }
    }

    private func addToInbox() {
        let title = PlanningInput.isExplicitIdea(trimmed) ? PlanningInput.idea(from: trimmed) : trimmed
        var idea = TaskSnapshot(title: title, start: .now, isAllDay: false, kind: .idea,
                                category: CategoryGuesser.guess(title), source: source)
        if let pastedURL { idea.notes = pastedURL.absoluteString }
        _ = taskStore.create(idea, actionName: "记录想法")
        taskStore.toast = Toast(message: "已放进收集箱", showsUndo: true)
        Haptics.success()
        dismiss()
    }

    /// Creates every draft (goals, ideas, events); a large draft with sub-steps becomes an idea plus its steps
    private func add(_ drafts: [CaptureDraft]) {
        let calendar = schedule.calendar
        var created: [TaskSnapshot] = []
        for draft in drafts {
            if draft.kind == .goal {
                if let goal = taskStore.createGoal(draft.title, period: draft.goalPeriod ?? .week, calendar: calendar) { created.append(goal) }
                continue
            }
            var task = draft.snapshot(fallbackStart: .now, source: source, calendar: calendar)
            if let pastedURL, task.notes.isEmpty { task.notes = pastedURL.absoluteString }
            created.append(taskStore.create(task, actionName: "收集"))
            if draft.isLarge, !draft.subtasks.isEmpty {
                for (index, step) in draft.subtasks.enumerated() {
                    created.append(taskStore.create(
                        TaskSnapshot(title: step, start: .now.addingTimeInterval(Double(index)), isAllDay: false, priority: task.priority,
                                     kind: .idea, sortOrder: Double(index), deadline: task.deadline, category: task.category,
                                     parentID: task.id, source: .agent),
                        actionName: "收集"))
                }
            }
        }
        guard let first = created.first else { return }
        if created.contains(where: { $0.kind == .event }) { Task { await notifications.requestAuthorizationIfNeeded() } }
        if first.kind == .event { schedule.anchorDate = calendar.startOfDay(for: first.start) }
        taskStore.toast = Toast(message: created.count == 1 ? "已添加「\(first.displayTitle)」" : "已添加 \(created.count) 项", showsUndo: true)
        Haptics.success()
        dismiss()
    }

    enum Kind { case event, idea, goal }

    private var kind: Kind {
        if PlanningInput.goal(from: trimmed) != nil { return .goal }
        if PlanningInput.isExplicitIdea(trimmed) { return .idea }
        return parsed.date == nil && parsed.start == nil ? .idea : .event
    }
}

/// The parsed items, before adding
private struct DraftList: View {
    let drafts: [CaptureDraft]
    let usedAI: Bool
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !usedAI {
                Label("按规则整理（AI 暂不可用）", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(drafts.enumerated()), id: \.offset) { _, draft in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: icon(draft.kind)).foregroundStyle(Palette.brand)
                        Text(draft.title).font(.headline)
                    }
                    FlowChips(chips: chips(draft))
                    if draft.isLarge && !draft.subtasks.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("会拆成 \(draft.subtasks.count) 步放进收集箱：").font(.caption).foregroundStyle(.secondary)
                            ForEach(draft.subtasks, id: \.self) { Text("· \($0)").font(.caption) }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 12)
            }
        }
    }

    private func icon(_ kind: TaskKind) -> String {
        switch kind {
        case .event: "calendar"
        case .idea: "lightbulb"
        case .goal: "target"
        }
    }

    private func chips(_ draft: CaptureDraft) -> [(String, String)] {
        var result: [(String, String)] = []
        switch draft.kind {
        case .goal: result.append(("target", draft.goalPeriod == .month ? "本月目标" : "本周目标"))
        case .idea: result.append(("tray", "收集箱"))
        case .event:
            if let start = draft.start {
                let when = draft.isAllDay ? "全天" : TimeText.hhmm(start, calendar: calendar)
                result.append(("clock", "\(TimeText.weekday(start, calendar: calendar)) \(when)"))
            }
        }
        if let minutes = draft.minutes { result.append(("timer", DurationText.minutes(minutes * 60))) }
        if let priority = draft.priority, priority != .normal { result.append(("flag", priority.title)) }
        if let deadline = draft.deadline { result.append(("hourglass", "截止 \(TimeText.weekday(deadline, calendar: calendar))")) }
        if let category = draft.category { result.append(("folder", category.title)) }
        if let effort = draft.effort { result.append(("bolt", effort.title)) }
        if let place = draft.place { result.append(("mappin", place)) }
        return result
    }
}

private struct MemoryCard: View {
    let memory: MemorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(memory.text, systemImage: "brain").font(.headline)
            if let constraint = memory.constraint {
                Text("排期时会避开：\(constraint.summary)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("作为背景信息记下").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12)
    }
}

extension MemoryConstraint {
    /// 「每周三 19:00–21:00」
    var summary: String {
        let names = ["", "日", "一", "二", "三", "四", "五", "六"]
        let days = weekdays.count == 7 ? "每天" : "每周" + weekdays.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0] }.joined(separator: "、")
        return "\(days) \(DateText.clock(startMinute))–\(DateText.clock(endMinute))"
    }
}

/// What the sentence turned into (rules): title, time, duration, priority, place
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
                Label("没有时间，会放进收集箱", systemImage: "lightbulb").foregroundStyle(.secondary)
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
