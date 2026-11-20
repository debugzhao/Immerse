import Charts
import ImmerseAgent
import ImmerseCore
import SwiftUI

/// 设置 → 秘书记忆: everything the secretary remembers, with where it came from; switch off, edit or delete each one
struct MemoryListView: View {
    @Environment(Secretary.self) private var secretary
    @State private var newText = ""
    @State private var draft: MemorySnapshot?
    @State private var isParsing = false

    var body: some View {
        let memories = secretary.allMemories()
        List {
            Section {
                HStack {
                    TextField("例如：周三晚上打球", text: $newText)
                        .submitLabel(.done)
                        .onSubmit(parse)
                    if isParsing { ProgressView() }
                }
            } footer: {
                Text("每周固定的时段会在排期时自动避开；其他的作为背景信息，帮秘书更懂你。")
            }
            if memories.isEmpty {
                Section { Text("还没有记忆。也可以在「+」里说「记住……」").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(memories) { memory in
                        MemoryRow(memory: memory)
                            .contentShape(Rectangle())
                            .onTapGesture { draft = memory }
                            .swipeActions {
                                Button(role: .destructive) { secretary.deleteMemory(memory.id) } label: { Label("删除", systemImage: "trash") }
                            }
                    }
                }
            }
        }
        .navigationTitle("秘书记忆")
        .sheet(item: $draft) { memory in
            MemoryEditor(memory: memory)
        }
    }

    private func parse() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isParsing = true
        Task {
            draft = await secretary.parseMemory(text)
            isParsing = false
            newText = ""
        }
    }
}

private struct MemoryRow: View {
    let memory: MemorySnapshot

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.text).foregroundStyle(memory.isActive ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(memory.constraint?.summary ?? kindTitle)
                    Text("·")
                    Text(memory.origin == .explicit ? "你说的" : "秘书推断")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !memory.isActive {
                Text("已停用").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var kindTitle: String {
        switch memory.kind {
        case .rule: "固定安排"
        case .preference: "偏好"
        case .fact: "背景信息"
        }
    }
}

/// Edit one memory; a rule's weekdays and hours can be adjusted by hand (also how it's set up without the AI)
struct MemoryEditor: View {
    @Environment(Secretary.self) private var secretary
    @Environment(\.dismiss) private var dismiss
    @State private var memory: MemorySnapshot
    @State private var isRule: Bool
    @State private var weekdays: Set<Int>
    @State private var start: Date
    @State private var end: Date

    private static let calendar = Calendar.app
    private static let dayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let dayNames = ["", "日", "一", "二", "三", "四", "五", "六"]

    init(memory: MemorySnapshot) {
        _memory = State(initialValue: memory)
        _isRule = State(initialValue: memory.constraint != nil)
        _weekdays = State(initialValue: memory.constraint?.weekdays ?? [])
        let day = Self.calendar.startOfDay(for: .now)
        _start = State(initialValue: day.addingTimeInterval(TimeInterval((memory.constraint?.startMinute ?? 19 * 60) * 60)))
        _end = State(initialValue: day.addingTimeInterval(TimeInterval((memory.constraint?.endMinute ?? 21 * 60) * 60)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("描述", text: $memory.text, axis: .vertical)
                    Toggle("启用", isOn: $memory.isActive)
                }
                Section {
                    Toggle("每周固定时段（排期时避开）", isOn: $isRule.animation())
                    if isRule {
                        HStack(spacing: 6) {
                            ForEach(Self.dayOrder, id: \.self) { day in
                                let selected = weekdays.contains(day)
                                Button(Self.dayNames[day]) {
                                    if selected { weekdays.remove(day) } else { weekdays.insert(day) }
                                }
                                .buttonStyle(.bordered)
                                .tint(selected ? Palette.brand : .gray)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        DatePicker("开始", selection: $start, displayedComponents: .hourAndMinute)
                        DatePicker("结束", selection: $end, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .navigationTitle("记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(memory.text.trimmingCharacters(in: .whitespaces).isEmpty || (isRule && (weekdays.isEmpty || minutes(end) <= minutes(start))))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Self.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func save() {
        if isRule {
            memory.kind = .rule
            memory.constraint = MemoryConstraint(weekdays: weekdays, startMinute: minutes(start), endMinute: minutes(end))
        } else {
            memory.constraint = nil
            if memory.kind == .rule { memory.kind = .fact }
        }
        memory.updatedAt = .now
        secretary.saveMemory(memory)
        Haptics.success()
        dismiss()
    }
}

/// 「本月读完 2 本书」→ minutes → "每周 3 次 × 50 分钟" → booked into high-energy slots
struct GoalCadenceSheet: View {
    let goal: TaskSnapshot
    @Environment(Secretary.self) private var secretary
    @Environment(TaskStore.self) private var taskStore
    @Environment(ScheduleState.self) private var schedule
    @Environment(\.dismiss) private var dismiss
    @State private var hours: Double
    @State private var isEstimating = false

    init(goal: TaskSnapshot) {
        self.goal = goal
        _hours = State(initialValue: Double(goal.targetMinutes ?? 600) / 60)
    }

    var body: some View {
        let plan = secretary.goalPlan(goal, targetMinutes: Int(hours * 60))
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $hours, in: 1...100, step: 1) {
                        LabeledContent("总共需要", value: "\(Int(hours)) 小时")
                    }
                    if secretary.ai.isAvailable {
                        Button {
                            isEstimating = true
                            Task {
                                if let minutes = await secretary.estimateGoalMinutes(goal) { hours = max((Double(minutes) / 60).rounded(), 1) }
                                isEstimating = false
                            }
                        } label: {
                            HStack { Label("让秘书估一下", systemImage: "sparkles"); if isEstimating { Spacer(); ProgressView() } }
                        }
                    }
                } header: {
                    Text(goal.displayTitle)
                } footer: {
                    Text("专注时间会计入目标进度")
                }
                if let plan {
                    Section {
                        LabeledContent("节奏", value: plan.cadence.summary)
                        LabeledContent("还需", value: DurationText.minutes(plan.cadence.remainingMinutes * 60))
                        if let proposal = plan.proposal {
                            Text("会在接下来的空档里安排 \(proposal.items.count) 次，优先放进你的高效时段").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("最近没有合适的空档").font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section { Text("目标已经完成或周期已结束").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("拆成节奏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("预览安排") {
                        var updated = goal
                        updated.targetMinutes = Int(hours * 60)
                        taskStore.update(updated, actionName: "设置目标时长")
                        let proposal = plan?.proposal
                        dismiss()
                        if let proposal { schedule.showProposal(proposal, secretary: secretary) }
                    }
                    .disabled(plan?.proposal == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Stats tab additions: when the user focuses best, and how far estimates are off
struct InsightsSection: View {
    @Environment(Secretary.self) private var secretary

    var body: some View {
        let insights = secretary.insights()
        let context = secretary.context()
        let ratios = Calibration.ratios(tasks: context.tasks, records: context.records).sorted { $0.key.rawValue < $1.key.rawValue }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("你的高效时段").font(.headline)
                Spacer()
                Text(insights.energy.peakHours().map { "\($0):00" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Chart(Array((6..<24).map { ($0, insights.energy.hourly[$0]) }), id: \.0) { hour, score in
                BarMark(x: .value("时", "\(hour)"), y: .value("精力", score))
                    .foregroundStyle(insights.energy.peakHours().contains(hour) ? Palette.brand : Palette.brand.opacity(0.35))
                    .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: ["6", "9", "12", "15", "18", "21"])
            }
            .frame(height: 120)
            Text(insights.energy.isPersonalized
                 ? "根据最近 \(insights.energy.sampleCount) 次专注统计，难的任务会优先排进这些时段"
                 : "专注记录还不多（\(insights.energy.sampleCount) 次），先按常见作息估计，用一周后会更准")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .glassCard()

        if !ratios.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("估时偏差").font(.headline)
                ForEach(ratios, id: \.key) { category, value in
                    HStack {
                        Text(category.title)
                        Spacer()
                        Text(value.ratio > 1 ? "平均超时 \(Int(((value.ratio - 1) * 100).rounded()))%" : "平均提前 \(Int(((1 - value.ratio) * 100).rounded()))%")
                            .foregroundStyle(abs(value.ratio - 1) > Calibration.threshold ? .orange : .secondary)
                        Text("\(value.samples) 次").font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                ForEach(insights.calibration) { CalibrationRow(insight: $0) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }
}
