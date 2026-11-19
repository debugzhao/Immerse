import SwiftUI

/// Notion-style event sheet: centered card + large title + property list + notes body. Create and edit share one form.
/// - Create: appears when `store.draft` is non-nil; ⌘↩ or Return in the title creates, Esc or clicking outside closes (nothing created, content kept until next time)
/// - Edit: appears when `store.editingTaskID` is non-nil; changes save immediately (undoable), Esc or clicking outside closes
struct TaskEditorOverlay: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            let height = min(max(geometry.size.height - 96, 360), 560)
            ZStack {
                if let id = store.editingTaskID {
                    TaskEditCard(taskID: id, height: height)
                        .id(id)
                } else if let draft = store.draft {
                    TaskCreateCard(initial: store.makeNewTask(for: draft), height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.snappy, value: store.isEditorPresented)
    }
}

// MARK: - Sheet shell

/// Translucent scrim + centered frosted-glass card
private struct EditorModal<Content: View>: View {
    let height: CGFloat
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .transition(.opacity)

            content
                .frame(width: 640, height: height)
                .glassSurface(.overlay, cornerRadius: 14)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }
}

// MARK: - Create

private struct TaskCreateCard: View {
    let height: CGFloat

    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @State private var task: TaskSnapshot
    /// Content was restored from the last unsaved draft
    @State private var isRestored: Bool
    @State private var didCreate = false
    @FocusState private var isTitleFocused: Bool

    init(initial: (task: TaskSnapshot, isRestored: Bool), height: CGFloat) {
        self.height = height
        _task = State(initialValue: initial.task)
        _isRestored = State(initialValue: initial.isRestored)
    }

    var body: some View {
        EditorModal(height: height, onDismiss: dismiss) {
            VStack(spacing: 0) {
                EditorTopBar(onClose: cancel) {
                    if isRestored {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward.circle")
                            Text("已恢复上次未保存的内容")
                            Button("清空", action: clearRestored)
                                .buttonStyle(.link)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    } else {
                        Text("新日程")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                TaskEditorForm(task: $task, isTitleFocused: $isTitleFocused, onSubmitTitle: create)
                Divider()
                HStack(spacing: 10) {
                    Text("↩ 或 ⌘↩ 创建 · Esc 关闭（填写的内容会保留）")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("取消", action: cancel)
                    Button("创建", action: create)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .onAppear {
            isTitleFocused = true
            // ⌘↩ in the menu also means "Start Focus"; make it create while the sheet is open
            store.submitDraft = create
        }
        .onDisappear {
            store.submitDraft = nil
            // Whether closed by Esc, Cancel, or clicking outside, keep what was filled in if nothing was created
            if !didCreate { store.keepUnsaved(task) }
        }
        // When the time changes, the dashed draft block on the calendar follows
        .onChange(of: task) { _, task in
            guard store.draft != nil else { return }
            let end = task.displayInterval(in: store.calendar).end
            store.draft = DraftEvent(start: task.start, end: task.isAllDay ? task.start : end, isAllDay: task.isAllDay)
        }
    }

    private func create() {
        guard store.draft != nil else { return }
        var snapshot = task
        snapshot.title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = taskStore.create(snapshot)
        didCreate = true
        store.unsavedDraft = nil
        store.draft = nil
        store.select(created.id)
    }

    private func cancel() {
        store.draft = nil
    }

    /// Content not to restore: clear the filled-in fields, keep the time
    private func clearRestored() {
        task = TaskSnapshot(title: "", start: task.start, end: task.end, isAllDay: task.isAllDay)
        isRestored = false
        store.unsavedDraft = nil
        isTitleFocused = true
    }

    /// Clicking outside the sheet: close without creating; filled-in content is kept for next time (saved in onDisappear)
    private func dismiss() {
        cancel()
    }
}

// MARK: - Edit

private struct TaskEditCard: View {
    let taskID: UUID
    let height: CGFloat

    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine
    @State private var draft: TaskSnapshot?
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        EditorModal(height: height, onDismiss: close) {
            VStack(spacing: 0) {
                EditorTopBar(onClose: close) {
                    if let draft { trailingActions(draft) }
                }
                if let draft {
                    TaskEditorForm(
                        task: Binding(get: { draft }, set: { commit($0) }),
                        isTitleFocused: $isTitleFocused,
                        onSubmitTitle: { isTitleFocused = false }
                    )
                } else {
                    Spacer()
                }
            }
        }
        .onAppear(perform: reload)
        // Sync after external changes (drag, undo, context menu); close if the event was deleted
        .onChange(of: taskStore.revision) { _, _ in reload() }
        .onDisappear { taskStore.breakCoalescing() }
    }

    @ViewBuilder
    private func trailingActions(_ task: TaskSnapshot) -> some View {
        let isActive = focusEngine.isFocusing(on: task.id)
        if task.kind != .idea {
            focusButton(task, isActive: isActive)
        }
        moreMenu(task)
    }

    private func focusButton(_ task: TaskSnapshot, isActive: Bool) -> some View {
        Button {
            if isActive { focusEngine.togglePause() } else { focusEngine.requestStart(task) }
        } label: {
            if isActive {
                Label(focusEngine.phase == .timeUp ? "时间到" : "\(focusEngine.isPaused ? "继续" : "暂停") · 剩余 \(focusEngine.remainingText)",
                      systemImage: focusEngine.isPaused ? "play.fill" : "pause.fill")
                    .monospacedDigit()
            } else {
                Label("开始专注 \(task.focusMinutes) 分钟", systemImage: "play.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(task.priority.color)
        .disabled(task.status == .done && !isActive)
    }

    private func moreMenu(_ task: TaskSnapshot) -> some View {
        Menu {
            Button(task.status == .done ? "标记为未完成" : "标记完成") { taskStore.toggleDone(task.id) }
            Divider()
            if task.kind == .idea {
                ForEach(GoalPeriod.allCases) { period in
                    Button("设为\(period.title)目标") { taskStore.makeGoal(task.id, period: period, calendar: store.calendar) }
                }
            } else {
                Button("移回收集箱") { taskStore.moveToInbox(task.id) }
            }
            Divider()
            Button(task.kind == .event ? "删除日程" : task.kind == .goal ? "删除目标" : "删除想法", role: .destructive) {
                store.select(nil)
                taskStore.delete(id: task.id)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private func close() {
        store.editingTaskID = nil
    }

    private func reload() {
        guard let latest = taskStore.task(id: taskID) else {
            close()
            return
        }
        if latest != draft { draft = latest }
    }

    private func commit(_ updated: TaskSnapshot) {
        guard let previous = draft, previous != updated else { return }
        draft = updated
        // When only text fields changed, coalesce undo so each keystroke is not its own step
        var textOnly = previous
        textOnly.title = updated.title
        textOnly.notes = updated.notes
        textOnly.place = updated.place
        let key = textOnly == updated ? "\(updated.id)-text" : nil
        taskStore.update(updated, coalescingKey: key)
    }
}

// MARK: - Top bar

private struct EditorTopBar<Trailing: View>: View {
    let onClose: () -> Void
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("关闭（Esc）")
            Spacer()
            trailing
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Form

/// Large title + property list + notes
private struct TaskEditorForm: View {
    @Binding var task: TaskSnapshot
    var isTitleFocused: FocusState<Bool>.Binding
    let onSubmitTitle: () -> Void

    @Environment(CalendarStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("无标题", text: $task.title)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                // A large plain TextField sometimes mismeasures its height and gets clipped; pin a fixed height
                .frame(height: 40)
                .focused(isTitleFocused)
                .onSubmit(onSubmitTitle)
                .padding(.horizontal, 6)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                kindRows
                PropertyRow(icon: "flag", title: "优先级") {
                    ChipPicker(options: Priority.allCases, selection: $task.priority,
                               title: \.title, color: \.color)
                }
                PropertyRow(icon: "circle.dashed", title: "状态") {
                    ChipPicker(options: TaskStatus.allCases, selection: $task.status,
                               title: \.title, color: \.color)
                }
                PropertyRow(icon: "mappin", title: "地点") {
                    TextField("空", text: Binding(
                        get: { task.place ?? "" },
                        set: { task.place = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                }
                if task.kind != .goal {
                    PropertyRow(icon: "timer", title: task.kind == .idea ? "预计时长" : "专注时长") {
                        FocusMinutesProperty(task: $task)
                    }
                }
            }

            Divider()
                .padding(.vertical, 14)

            NotesEditor(text: $task.notes)
        }
        .padding(.horizontal, 42)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The rows that depend on what the task is
    @ViewBuilder
    private var kindRows: some View {
        switch task.kind {
        case .event:
            PropertyRow(icon: "clock", title: "时间") {
                TimeProperty(task: $task)
            }
            if let goalID = task.goalID {
                PropertyRow(icon: "target", title: "所属目标") {
                    LinkedGoalProperty(goalID: goalID)
                }
            }
        case .idea:
            PropertyRow(icon: "tray", title: "收集箱") {
                IdeaScheduleProperty(task: task)
            }
        case .goal:
            PropertyRow(icon: "calendar", title: "周期") {
                GoalPeriodProperty(task: $task)
            }
            PropertyRow(icon: "hourglass", title: "目标时长") {
                GoalTargetProperty(task: $task)
            }
            PropertyRow(icon: "chart.bar", title: "进度") {
                GoalProgressProperty(goal: task)
            }
        }
    }
}

/// One property row: icon + name on the left, value on the right; the whole row highlights slightly on hover
private struct PropertyRow<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.045 : 0))
        )
        .onHover { isHovering = $0 }
    }
}

/// Uniform style for property value buttons: light background on hover
private struct HoverButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.07 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - Time

/// Time row: the date is display-only (follows the day selected on the calendar); start / end times use large buttons + a 15-minute-step list
private struct TimeProperty: View {
    @Binding var task: TaskSnapshot
    @Environment(CalendarStore.self) private var store

    private var calendar: Calendar { store.calendar }

    var body: some View {
        HStack(spacing: 10) {
            Text(dayText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if task.isAllDay {
                Text("全天")
                    .font(.system(size: 13, weight: .medium))
            } else {
                let interval = task.displayInterval(in: calendar)
                TimeSlotButton(
                    title: TimeText.hhmm(task.start, calendar: calendar),
                    options: TimeSlots.starts(on: task.start, calendar: calendar),
                    selected: task.start,
                    detail: { _ in nil },
                    onPick: { task = EventEditing.movingStart(of: task, to: $0, calendar: calendar) }
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TimeSlotButton(
                    title: endTitle(interval.end),
                    options: TimeSlots.ends(after: task.start, calendar: calendar),
                    selected: interval.end,
                    presets: TimeSlots.durationPresets,
                    detail: { TimeSlots.durationText(from: task.start, to: $0) },
                    onPick: { task.end = $0 },
                    onPreset: { task.end = task.start.addingTimeInterval(TimeInterval($0 * 60)) }
                )
                Text(TimeSlots.durationText(from: interval.start, to: interval.end))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Toggle("全天", isOn: allDayBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// "11月18日 周三", with the year included when it is not this year
    private var dayText: String {
        let c = calendar.dateComponents([.year, .month, .day], from: task.start)
        let day = "\(c.month ?? 0)月\(c.day ?? 0)日 \(TimeText.weekday(task.start, calendar: calendar))"
        return c.year == calendar.component(.year, from: .now) ? day : "\(c.year ?? 0)年\(day)"
    }

    private func endTitle(_ end: Date) -> String {
        let text = TimeText.hhmm(end, calendar: calendar)
        let days = calendar.dayOffset(from: task.start, to: end.addingTimeInterval(-1))
        return days > 0 ? "\(text) 次日" : text
    }

    private var allDayBinding: Binding<Bool> {
        Binding(
            get: { task.isAllDay },
            set: { isAllDay in
                var updated = task
                if isAllDay {
                    updated.start = calendar.startOfDay(for: updated.start)
                    updated.end = nil
                } else {
                    // All-day to timed: place at 9:00 that day, duration 1 hour
                    let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: updated.start) ?? updated.start
                    updated.start = start
                    updated.end = start.addingTimeInterval(3600)
                }
                updated.isAllDay = isAllDay
                task = updated
            }
        )
    }
}

/// Large time button; opens a scrollable time list
private struct TimeSlotButton: View {
    let title: String
    let options: [Date]
    let selected: Date
    var presets: [Int] = []
    let detail: (Date) -> String?
    let onPick: (Date) -> Void
    var onPreset: (Int) -> Void = { _ in }

    @Environment(CalendarStore.self) private var store
    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button { isPresented = true } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isPresented ? 0.12 : isHovering ? 0.09 : 0.055))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if !presets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        Button {
                            onPreset(minutes)
                            isPresented = false
                        } label: {
                            Text(verbatim: "\(minutes) 分钟")
                                .fixedSize()
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(options, id: \.self) { option in
                            row(option)
                                .id(option)
                        }
                    }
                    .padding(6)
                }
                .onAppear {
                    // Scroll the current time to the middle when opened
                    let target = options.min { abs($0.timeIntervalSince(selected)) < abs($1.timeIntervalSince(selected)) }
                    if let target { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
        .frame(width: presets.isEmpty ? 150 : 270, height: 320)
    }

    private func row(_ option: Date) -> some View {
        let isSelected = abs(option.timeIntervalSince(selected)) < 60
        let calendar = store.calendar
        return Button {
            onPick(option)
            isPresented = false
        } label: {
            HStack {
                Text(TimeText.hhmm(option, calendar: calendar))
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .monospacedDigit()
                if let detail = detail(option) {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
                Spacer()
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(TimeRowButtonStyle(isSelected: isSelected))
    }
}

/// Time list row: light highlight on hover (the selected row already uses the accent color, so do not stack)
private struct TimeRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(!isSelected && isHovering ? 0.07 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - Single-select tags (priority / status)

private struct Chip: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.16), in: Capsule())
    }
}

/// Notion-style single select: click the tag to pop up the option list
private struct ChipPicker<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let color: (Value) -> Color
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Chip(title: title(selection), color: color(selection))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack {
                            Chip(title: title(option), color: color(option))
                            Spacer()
                            if option == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverButtonStyle())
                }
            }
            .padding(6)
            .frame(width: 170)
        }
    }
}

// MARK: - Focus duration

private struct FocusMinutesProperty: View {
    @Binding var task: TaskSnapshot
    @State private var isPresented = false

    private static let presets = [15, 25, 30, 45, 60, 90, 120]

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                Text(verbatim: "\(task.focusMinutes) 分钟")
                    .foregroundStyle(.primary)
                if task.plannedMinutes == nil {
                    Text("按日程时长")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .monospacedDigit()
        }
        .buttonStyle(HoverButtonStyle())
        .padding(.leading, -4)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                option("按日程时长", isSelected: task.plannedMinutes == nil) { task.plannedMinutes = nil }
                Divider().padding(.vertical, 2)
                ForEach(Self.presets, id: \.self) { minutes in
                    option("\(minutes) 分钟", isSelected: task.plannedMinutes == minutes) { task.plannedMinutes = minutes }
                }
                Divider().padding(.vertical, 2)
                Stepper(value: Binding(get: { task.focusMinutes }, set: { task.plannedMinutes = $0 }), in: 5...480, step: 5) {
                    Text(verbatim: "自定义 \(task.focusMinutes) 分钟")
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
                .padding(.horizontal, 4)
            }
            .padding(6)
            .frame(width: 190)
        }
    }

    private func option(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            isPresented = false
        } label: {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }
}

// MARK: - Notes

private struct NotesEditor: View {
    @Binding var text: String

    var body: some View {
        MarkdownEditor(text: $text)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("添加备注…  支持 Markdown：# 标题、**粗体**、- 列表、- [ ] 待办")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.top, MarkdownEditor.topInset)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
    }
}

// MARK: - Inbox / goal properties

/// Idea: not scheduled yet; quick actions to schedule or promote it
private struct IdeaScheduleProperty: View {
    let task: TaskSnapshot
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        HStack(spacing: 8) {
            Text("还没安排")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("安排到今天") {
                let start = store.defaultNewEventInterval(now: .now).start
                if let event = taskStore.schedule(task.id, at: start, calendar: store.calendar) {
                    store.editingTaskID = nil
                    store.reveal(event)
                }
            }
            ForEach(GoalPeriod.allCases) { period in
                Button("设为\(period.title)目标") { taskStore.makeGoal(task.id, period: period, calendar: store.calendar) }
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}

/// Goal: this week / this month, plus the actual date range and days left
private struct GoalPeriodProperty: View {
    @Binding var task: TaskSnapshot
    @Environment(CalendarStore.self) private var store

    var body: some View {
        let calendar = store.calendar
        let interval = task.displayInterval(in: calendar)
        let last = interval.end.addingTimeInterval(-1)
        HStack(spacing: 8) {
            ForEach(GoalPeriod.allCases) { period in
                let range = period.range(containing: .now, calendar: calendar)
                let isOn = calendar.isDate(task.start, inSameDayAs: range.start)
                    && calendar.isDate(last, inSameDayAs: range.lastDay)
                Button {
                    task.start = range.start
                    task.end = range.lastDay
                    task.isAllDay = true
                } label: {
                    Text(period.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("\(day(task.start)) – \(day(last))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func day(_ date: Date) -> String {
        "\(store.calendar.component(.month, from: date))月\(store.calendar.component(.day, from: date))日"
    }
}

/// Goal: planned total focus time
private struct GoalTargetProperty: View {
    @Binding var task: TaskSnapshot
    @State private var isPresented = false

    private static let presets = [3, 5, 10, 20, 30]

    var body: some View {
        Button { isPresented = true } label: {
            Text(task.targetMinutes.map { "\($0 / 60) 小时" } ?? "不设（按完成次数算进度）")
                .font(.system(size: 13))
                .foregroundStyle(task.targetMinutes == nil ? .secondary : .primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -4)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                option("不设", isSelected: task.targetMinutes == nil) { task.targetMinutes = nil }
                Divider().padding(.vertical, 2)
                ForEach(Self.presets, id: \.self) { hours in
                    option("\(hours) 小时", isSelected: task.targetMinutes == hours * 60) { task.targetMinutes = hours * 60 }
                }
                Divider().padding(.vertical, 2)
                Stepper(value: Binding(get: { (task.targetMinutes ?? 0) / 60 }, set: { task.targetMinutes = max($0, 1) * 60 }),
                        in: 1...200) {
                    Text(verbatim: "自定义 \((task.targetMinutes ?? 0) / 60) 小时")
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
                .padding(.horizontal, 4)
            }
            .padding(6)
            .frame(width: 190)
        }
    }

    private func option(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            isPresented = false
        } label: {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Goal: progress bar + focus time / sessions + next scheduled session
private struct GoalProgressProperty: View {
    let goal: TaskSnapshot
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine

    var body: some View {
        let progress = goalProgress(goal, taskStore: taskStore, focusEngine: focusEngine, calendar: store.calendar)
        let next = taskStore.events(linkedTo: goal.id).first { $0.start > .now && $0.status != .done }
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ProgressBar(fraction: progress.fraction, color: goal.status == .done ? .green : goal.priority.color)
                    .frame(width: 160)
                Text(verbatim: "\(progress.percent)%  ·  \(progress.summary)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                if progress.isBehind {
                    Text("进度落后").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Text(nextText(next, progress: progress))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func nextText(_ next: TaskSnapshot?, progress: GoalProgress) -> String {
        let left = "还剩 \(progress.daysLeft) 天"
        guard let next else { return "\(left) · 从侧栏把目标拖到日历上，安排下一次时间" }
        let c = store.calendar
        return "\(left) · 下一次：\(c.component(.month, from: next.start))月\(c.component(.day, from: next.start))日 \(TimeText.hhmm(next.start, calendar: c))"
    }
}

/// Event linked to a goal: shows the goal, click to open it
private struct LinkedGoalProperty: View {
    let goalID: UUID
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        if let goal = taskStore.task(id: goalID) {
            Button { store.openEditor(goal.id) } label: {
                Label(goal.displayTitle, systemImage: "target")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(goal.priority.color.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("打开目标")
        } else {
            Text("目标已删除").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}
