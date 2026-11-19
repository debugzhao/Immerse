import SwiftUI

/// Notion 风格的日程弹窗：居中卡片 + 大标题 + 属性列表 + 备注正文。新建和编辑共用一套表单。
/// - 新建：`store.draft` 不为空时出现；⌘↩ 或在标题里回车创建，Esc 取消，点外面有标题就创建
/// - 编辑：`store.editingTaskID` 不为空时出现；改动立即保存（可撤销），Esc 或点外面关闭
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

// MARK: - 弹窗外壳

/// 半透明遮罩 + 居中的毛玻璃卡片
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

// MARK: - 新建

private struct TaskCreateCard: View {
    let height: CGFloat

    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @State private var task: TaskSnapshot
    /// 内容是从上次没保存的草稿恢复的
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
            // 菜单里的 ⌘↩ 也是「开始专注」，弹窗打开时让它改为创建
            store.submitDraft = create
        }
        .onDisappear {
            store.submitDraft = nil
            // 不管是 Esc、点取消还是点外面，没创建就把填写的内容留着
            if !didCreate { store.keepUnsaved(task) }
        }
        // 改时间时，日历上的虚线草稿块跟着移动
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

    /// 不要恢复的内容：清空填写项，时间保留
    private func clearRestored() {
        task = TaskSnapshot(title: "", start: task.start, end: task.end, isAllDay: task.isAllDay)
        isRestored = false
        store.unsavedDraft = nil
        isTitleFocused = true
    }

    /// 点弹窗外面：写了标题就保留（和 Notion 一样），否则当作取消
    private func dismiss() {
        if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cancel() } else { create() }
    }
}

// MARK: - 编辑

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
        // 外部修改（拖拽、撤销、右键菜单）后同步；日程被删掉就关闭
        .onChange(of: taskStore.revision) { _, _ in reload() }
        .onDisappear { taskStore.breakCoalescing() }
    }

    @ViewBuilder
    private func trailingActions(_ task: TaskSnapshot) -> some View {
        let isActive = focusEngine.isFocusing(on: task.id)
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

        Menu {
            Button(task.status == .done ? "标记为未完成" : "标记完成") { taskStore.toggleDone(task.id) }
            Divider()
            Button("删除日程", role: .destructive) {
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
        // 只改了文字字段时合并撤销，避免每敲一个字就是一步
        var textOnly = previous
        textOnly.title = updated.title
        textOnly.notes = updated.notes
        textOnly.place = updated.place
        let key = textOnly == updated ? "\(updated.id)-text" : nil
        taskStore.update(updated, coalescingKey: key)
    }
}

// MARK: - 顶栏

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

// MARK: - 表单

/// 大标题 + 属性列表 + 备注
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
                // 大字号的 plain TextField 偶尔测不准高度会被裁掉，固定一个高度
                .frame(height: 40)
                .focused(isTitleFocused)
                .onSubmit(onSubmitTitle)
                .padding(.horizontal, 6)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                PropertyRow(icon: "clock", title: "时间") {
                    TimeProperty(task: $task)
                }
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
                PropertyRow(icon: "timer", title: "专注时长") {
                    FocusMinutesProperty(task: $task)
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
}

/// 一行属性：左边图标 + 名称，右边值；悬停时整行轻微高亮
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

/// 属性值按钮的统一样式：悬停加浅底
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

// MARK: - 时间

/// 时间行：日期只展示（跟随日历上选的那天），开始 / 结束时间用大按钮 + 15 分钟刻度列表选择
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

    /// 「11月18日 周三」，不是今年时带年份
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
                    // 全天改成定时：放到当天 9:00，时长 1 小时
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

/// 大号的时间按钮，点开是可滚动的时间列表
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
                    // 打开时把当前时间滚到中间
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

/// 时间列表行：悬停时浅色高亮（选中行已经是强调色，不再叠加）
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

// MARK: - 单选标签（优先级 / 状态）

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

/// Notion 式的单选：点标签弹出选项列表
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

// MARK: - 专注时长

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

// MARK: - 备注

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
