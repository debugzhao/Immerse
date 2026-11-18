import SwiftUI

/// 右侧详情面板：编辑选中日程的全部字段。每次修改立即保存，连续输入合并成一步撤销。
struct TaskInspectorView: View {
    let taskID: UUID

    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @Environment(FocusEngine.self) private var focusEngine

    @State private var draft: TaskSnapshot?
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        Group {
            if let draft {
                form(Binding(get: { draft }, set: { commit($0) }))
            } else {
                ContentUnavailableView("日程不存在", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: taskID) { _, _ in
            taskStore.breakCoalescing()
            reload()
        }
        // 外部修改（拖拽、撤销、右键菜单）后同步
        .onChange(of: taskStore.revision) { _, _ in reload() }
        .onChange(of: store.wantsTitleFocus, initial: true) { _, wants in
            guard wants else { return }
            isTitleFocused = true
            store.wantsTitleFocus = false
        }
    }

    // MARK: - 表单

    private func form(_ task: Binding<TaskSnapshot>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(task)
                Divider()
                timeSection(task)
                Divider()
                attributeSection(task)
                Divider()
                notesSection(task)
                Spacer(minLength: 12)
                actions(task.wrappedValue)
            }
            .padding(18)
        }
    }

    private func header(_ task: Binding<TaskSnapshot>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("日程标题", text: task.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .focused($isTitleFocused)
                .lineLimit(1...3)
            HStack(spacing: 6) {
                Circle().fill(task.wrappedValue.priority.color).frame(width: 8, height: 8)
                Text("\(task.wrappedValue.priority.title) · \(task.wrappedValue.status.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timeSection(_ task: Binding<TaskSnapshot>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("全天", isOn: allDayBinding(task))
                .toggleStyle(.switch)
                .controlSize(.small)

            if task.wrappedValue.isAllDay {
                row("开始") {
                    DatePicker("", selection: startBinding(task), displayedComponents: .date).labelsHidden()
                }
                row("结束") {
                    DatePicker("", selection: allDayEndBinding(task), in: task.wrappedValue.start..., displayedComponents: .date)
                        .labelsHidden()
                }
            } else {
                row("开始") {
                    DatePicker("", selection: startBinding(task)).labelsHidden()
                }
                row("结束") {
                    DatePicker("", selection: timedEndBinding(task),
                               in: task.wrappedValue.start.addingTimeInterval(EventEditing.minimumDuration)...)
                        .labelsHidden()
                }
            }

            row("专注时长") {
                HStack(spacing: 6) {
                    Text(verbatim: "\(task.wrappedValue.focusMinutes) 分钟")
                        .monospacedDigit()
                    Stepper("", value: plannedBinding(task), in: 5...480, step: 5).labelsHidden()
                    if task.wrappedValue.plannedMinutes != nil {
                        Button("自动") { task.wrappedValue.plannedMinutes = nil }
                            .buttonStyle(.link)
                            .help("恢复为按日程时长计算")
                    }
                }
            }
        }
    }

    private func attributeSection(_ task: Binding<TaskSnapshot>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row("优先级") {
                Picker("", selection: task.priority) {
                    ForEach(Priority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            row("状态") {
                Picker("", selection: task.status) {
                    ForEach(TaskStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            row("地点") {
                TextField("添加地点", text: Binding(
                    get: { task.wrappedValue.place ?? "" },
                    set: { task.wrappedValue.place = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func notesSection(_ task: Binding<TaskSnapshot>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备注")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: task.notes)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 120)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func actions(_ task: TaskSnapshot) -> some View {
        VStack(spacing: 8) {
            let isActive = focusEngine.isFocusing(on: task.id)
            Button {
                if isActive { focusEngine.togglePause() } else { focusEngine.requestStart(task) }
            } label: {
                Label(isActive ? (focusEngine.isPaused ? "继续专注" : "暂停专注") : "开始专注 \(task.focusMinutes) 分钟",
                      systemImage: isActive && !focusEngine.isPaused ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(task.status == .done && !isActive)

            if isActive {
                Text(focusEngine.phase == .timeUp ? "时间到" : "剩余 \(focusEngine.remainingText)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    taskStore.toggleDone(task.id)
                } label: {
                    Label(task.status == .done ? "标记未完成" : "标记完成", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    store.select(nil)
                    taskStore.delete(id: task.id)
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - 绑定

    private func startBinding(_ task: Binding<TaskSnapshot>) -> Binding<Date> {
        Binding(
            get: { task.wrappedValue.start },
            set: { task.wrappedValue = EventEditing.movingStart(of: task.wrappedValue, to: $0, calendar: store.calendar) }
        )
    }

    private func timedEndBinding(_ task: Binding<TaskSnapshot>) -> Binding<Date> {
        Binding(
            get: { task.wrappedValue.displayInterval(in: store.calendar).end },
            set: { task.wrappedValue.end = $0 }
        )
    }

    private func allDayEndBinding(_ task: Binding<TaskSnapshot>) -> Binding<Date> {
        Binding(
            get: { task.wrappedValue.end ?? task.wrappedValue.start },
            set: { newValue in
                let calendar = store.calendar
                task.wrappedValue.end = calendar.isDate(newValue, inSameDayAs: task.wrappedValue.start) ? nil : newValue
            }
        )
    }

    private func allDayBinding(_ task: Binding<TaskSnapshot>) -> Binding<Bool> {
        Binding(
            get: { task.wrappedValue.isAllDay },
            set: { isAllDay in
                var updated = task.wrappedValue
                let calendar = store.calendar
                if isAllDay {
                    updated.start = calendar.startOfDay(for: updated.start)
                    updated.end = nil
                } else {
                    // 全天改成定时：放到当天 9:00，时长 1 小时
                    let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: updated.start) ?? updated.start
                    updated.start = start
                    updated.end = start.addingTimeInterval(3600)
                }
                updated.isAllDay = isAllDay
                task.wrappedValue = updated
            }
        )
    }

    private func plannedBinding(_ task: Binding<TaskSnapshot>) -> Binding<Int> {
        Binding(
            get: { task.wrappedValue.focusMinutes },
            set: { task.wrappedValue.plannedMinutes = $0 }
        )
    }

    // MARK: - 保存

    private func reload() {
        let latest = taskStore.task(id: taskID)
        if latest != draft { draft = latest }
    }

    private func commit(_ updated: TaskSnapshot) {
        guard let previous = draft, previous != updated else { return }
        draft = updated
        // 只改了文字字段时合并撤销，避免每敲一个字就是一步
        var textOnly = previous
        textOnly.title = updated.title
        textOnly.notes = updated.notes
        textOnly.place = updated.place
        let key = textOnly == updated ? "\(updated.id)-text" : nil
        taskStore.update(updated, coalescingKey: key)
    }
}
