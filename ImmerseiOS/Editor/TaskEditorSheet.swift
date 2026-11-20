import ImmerseAgent
import ImmerseCore
import SwiftUI

/// Edit an event (or create one) in a half-height sheet that can be pulled up to full height.
/// Changes stay local until "保存", so swiping the sheet away discards them.
struct TaskEditorSheet: View {
    let target: EditorTarget

    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(ScheduleState.self) private var schedule
    @Environment(Secretary.self) private var secretary
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TaskSnapshot
    @State private var hasDeadline: Bool
    @State private var confirmsDelete = false

    init(target: EditorTarget) {
        self.target = target
        let initial: TaskSnapshot
        switch target {
        case .new(let task): initial = task
        case .existing: initial = TaskSnapshot(title: "", start: .now, isAllDay: false)
        }
        _draft = State(initialValue: initial)
        _hasDeadline = State(initialValue: initial.deadline != nil)
    }

    private var isNew: Bool { if case .new = target { true } else { false } }
    private var calendar: Calendar { schedule.calendar }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $draft.title, axis: .vertical)
                        .font(.title3.weight(.semibold))
                    Picker("优先级", selection: $draft.priority) {
                        ForEach(Priority.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !isNew {
                        Picker("状态", selection: $draft.status) {
                            ForEach(TaskStatus.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    Toggle("全天", isOn: $draft.isAllDay.animation())
                    DatePicker("开始", selection: startBinding,
                               displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
                    DatePicker("结束", selection: endBinding, in: draft.start...,
                               displayedComponents: draft.isAllDay ? .date : [.date, .hourAndMinute])
                    if !draft.isAllDay {
                        Stepper(value: focusMinutesBinding, in: 5...480, step: 5) {
                            LabeledContent("专注时长", value: DurationText.minutes(draft.focusMinutes * 60))
                        }
                    }
                }

                Section("秘书会用到") {
                    Picker("分类", selection: $draft.category) {
                        Text("未分类").tag(TaskCategory?.none)
                        ForEach(TaskCategory.allCases) { Text($0.title).tag(TaskCategory?.some($0)) }
                    }
                    Picker("难度", selection: $draft.effort) {
                        Text("未设置").tag(TaskEffort?.none)
                        ForEach(TaskEffort.allCases) { Text($0.title).tag(TaskEffort?.some($0)) }
                    }
                    Toggle("截止日期", isOn: $hasDeadline.animation())
                    if hasDeadline {
                        DatePicker("截止", selection: deadlineBinding, displayedComponents: [.date, .hourAndMinute])
                    }
                    let goals = GoalQueries.active(taskStore: taskStore, calendar: calendar)
                    if !goals.isEmpty {
                        Picker("关联目标", selection: $draft.goalID) {
                            Text("无").tag(UUID?.none)
                            ForEach(goals) { Text($0.displayTitle).tag(UUID?.some($0.id)) }
                        }
                    }
                }

                Section {
                    TextField("地点", text: placeBinding)
                    TextField("备注（支持 Markdown，- [ ] 写待办）", text: $draft.notes, axis: .vertical)
                        .lineLimit(4...12)
                }

                if !isNew {
                    Section {
                        if !focusEngine.isFocusing(on: draft.id) && draft.status != .done {
                            Button {
                                save()
                                dismiss()
                                startFocusWithBriefing(draft, secretary: secretary, schedule: schedule, focusEngine: focusEngine)
                            } label: {
                                Label("开始专注 \(DurationText.minutes(draft.focusMinutes * 60))", systemImage: "play.fill")
                            }
                        }
                        if hasDeadline && draft.status != .done {
                            Button {
                                save()
                                let proposal = secretary.backPlan(taskStore.task(id: draft.id) ?? draft)
                                dismiss()
                                if let proposal {
                                    schedule.showProposal(proposal, secretary: secretary)
                                } else if let notice = secretary.notice {
                                    taskStore.toast = Toast(message: notice)
                                    secretary.notice = nil
                                }
                            } label: {
                                Label("按截止日倒推安排", systemImage: "calendar.badge.clock")
                            }
                        }
                        if secretary.ai.isAvailable && draft.status != .done {
                            Button {
                                Task {
                                    let proposal = await secretary.splitProposal(draft)
                                    dismiss()
                                    if let proposal { schedule.showProposal(proposal, secretary: secretary) }
                                }
                            } label: {
                                Label("拆成小步骤", systemImage: "list.bullet.indent")
                            }
                        }
                        Button("删除日程", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "新建日程" : "编辑日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "添加" : "保存") {
                        save()
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("删除「\(draft.displayTitle)」？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    taskStore.delete(id: draft.id)
                    dismiss()
                }
            }
            .onAppear(perform: loadExisting)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func loadExisting() {
        guard case .existing(let id) = target, let task = taskStore.task(id: id) else { return }
        draft = task
        hasDeadline = task.deadline != nil
    }

    private func save() {
        var task = draft
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasDeadline {
            task.deadline = nil
        } else if task.deadline == nil {
            // Toggled on but the picker was never touched: it showed the event's end, so save that
            task.deadline = task.displayInterval(in: calendar).end
        }
        if isNew {
            _ = taskStore.create(task)
        } else if task != taskStore.task(id: task.id) {
            taskStore.update(task)
        }
    }

    // MARK: - Bindings that keep start / end consistent

    /// Moving the start keeps the duration, like dragging the block
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { draft = EventEditing.movingStart(of: draft, to: $0, calendar: calendar) })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { draft.end ?? draft.displayInterval(in: calendar).end },
                set: { draft.end = max($0, draft.start) })
    }

    private var focusMinutesBinding: Binding<Int> {
        Binding(get: { draft.focusMinutes }, set: { draft.plannedMinutes = $0 })
    }

    private var deadlineBinding: Binding<Date> {
        Binding(get: { draft.deadline ?? draft.displayInterval(in: calendar).end }, set: { draft.deadline = $0 })
    }

    private var placeBinding: Binding<String> {
        Binding(get: { draft.place ?? "" }, set: { draft.place = $0.isEmpty ? nil : $0 })
    }
}
