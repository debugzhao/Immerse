import SwiftUI

/// ⌘K 命令面板：输入自然语言快速新建日程，或者执行命令、跳转到日程。
/// ↩ 执行选中项（默认第一项）；⌘↩ 新建并立即开始专注；↑↓ 切换；Esc 关闭。
struct CommandPaletteView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(\.openSettings) private var openSettings

    @State private var text = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private struct Item: Identifiable {
        enum Kind { case create, command, task }
        let id: String
        let kind: Kind
        let icon: String
        let title: String
        var subtitle: String?
        var tint: Color = .secondary
        let action: () -> Void
    }

    var body: some View {
        let items = makeItems()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                TextField("输入「明天下午3点 阅读 1小时 重要」或搜索命令…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFocused)
                    .onSubmit { run(items, at: selection) }
                    .onKeyPress(.downArrow) { move(1, count: items.count) }
                    .onKeyPress(.upArrow) { move(-1, count: items.count) }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        createAndFocus()
                        return .handled
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            if !items.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == selection)
                                    .id(item.id)
                                    .onTapGesture { run(items, at: index) }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: min(CGFloat(items.count) * 46 + 16, 380))
                    .onChange(of: selection) { _, index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                }
            }

            footer
        }
        .frame(width: 600)
        .glassSurface(.overlay, cornerRadius: 16)
        .onAppear { isFocused = true }
        .onChange(of: text) { _, _ in selection = 0 }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 14))
                .foregroundStyle(item.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: item.kind == .create ? .semibold : .regular))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isSelected {
                Text(item.kind == .create ? "↩ 创建  ⌘↩ 创建并专注" : "↩")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        )
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("支持：今天 / 明天 / 周三 / 11月20日 · 下午3点 / 14:00-15:30 · 1小时 · 重要 / !!! · @地点")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - 条目

    private func makeItems() -> [Item] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var items: [Item] = []

        if !trimmed.isEmpty {
            let parsed = NaturalLanguageParser.parse(trimmed, calendar: store.calendar)
            let draft = parsed.makeSnapshot(now: .now, calendar: store.calendar)
            if !draft.title.isEmpty {
                items.append(Item(id: "create", kind: .create, icon: "plus.circle.fill",
                                  title: "新建「\(draft.title)」", subtitle: preview(draft),
                                  tint: draft.priority.color) { create(draft, startFocus: false) })
            }
        }

        let commands = commandItems().filter { trimmed.isEmpty || $0.title.localizedStandardContains(trimmed) }
        items.append(contentsOf: commands)

        if !trimmed.isEmpty {
            items.append(contentsOf: taskStore.search(trimmed, limit: 6).map { task in
                Item(id: "task-\(task.id)", kind: .task, icon: "calendar", title: task.displayTitle,
                     subtitle: preview(task), tint: task.priority.color) {
                    store.reveal(task)
                    close()
                }
            })
        }
        return items
    }

    private func commandItems() -> [Item] {
        var items = [
            Item(id: "today", kind: .command, icon: "calendar.circle", title: "回到今天", subtitle: "T") {
                store.goToToday(); close()
            },
            Item(id: "day", kind: .command, icon: "1.square", title: "切换到日视图", subtitle: "D") {
                store.mode = .day; close()
            },
            Item(id: "week", kind: .command, icon: "7.square", title: "切换到周视图", subtitle: "W") {
                store.mode = .week; close()
            },
            Item(id: "month", kind: .command, icon: "calendar", title: "切换到月视图", subtitle: "M") {
                store.mode = .month; close()
            },
        ]
        if focusEngine.isActive {
            items.insert(Item(id: "immersive", kind: .command, icon: "sparkles.tv", title: "进入沉浸模式",
                              subtitle: "全屏显示倒计时") {
                close(); focusEngine.isImmersivePresented = true
            }, at: 0)
            items.insert(Item(id: "pause", kind: .command, icon: focusEngine.isPaused ? "play.fill" : "pause.fill",
                              title: focusEngine.isPaused ? "继续专注" : "暂停专注",
                              subtitle: focusEngine.session?.taskTitle) {
                focusEngine.togglePause(); close()
            }, at: 0)
        } else if let task = taskStore.task(id: store.selectedTaskID), task.status != .done {
            items.insert(Item(id: "focus", kind: .command, icon: "play.circle", title: "开始专注「\(task.displayTitle)」",
                              subtitle: "\(task.focusMinutes) 分钟") {
                focusEngine.requestStart(task); close()
            }, at: 0)
        }
        items.append(Item(id: "settings", kind: .command, icon: "gearshape", title: "打开设置", subtitle: "⌘,") {
            close(); openSettings()
        })
        return items
    }

    private func preview(_ task: TaskSnapshot) -> String {
        let calendar = store.calendar
        let day = "\(calendar.component(.month, from: task.start))月\(calendar.component(.day, from: task.start))日 \(TimeText.weekday(task.start, calendar: calendar))"
        var parts: [String] = []
        if task.isAllDay {
            parts.append("📅 \(day) · 全天")
        } else {
            let interval = task.displayInterval(in: calendar)
            parts.append("📅 \(day) \(TimeText.range(interval.start, interval.end, calendar: calendar))")
        }
        if let planned = task.plannedMinutes { parts.append("⏱ \(planned) 分钟") }
        parts.append(task.priority.title)
        if let place = task.place { parts.append("📍\(place)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 动作

    private func move(_ delta: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selection = (selection + delta + count) % count
        return .handled
    }

    private func run(_ items: [Item], at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].action()
    }

    private func createAndFocus() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let draft = NaturalLanguageParser.parse(trimmed, calendar: store.calendar)
            .makeSnapshot(now: .now, calendar: store.calendar)
        guard !draft.title.isEmpty else { return }
        create(draft, startFocus: true)
    }

    private func create(_ draft: TaskSnapshot, startFocus: Bool) {
        let task = taskStore.create(draft)
        store.reveal(task)
        close()
        if startFocus { focusEngine.requestStart(task) }
    }

    private func close() {
        store.isCommandPalettePresented = false
    }
}

/// 命令面板的浮层容器：半透明遮罩 + 顶部居中
struct CommandPaletteOverlay: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        ZStack(alignment: .top) {
            if store.isCommandPalettePresented {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { store.isCommandPalettePresented = false }
                    .transition(.opacity)
                CommandPaletteView()
                    .padding(.top, 90)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: store.isCommandPalettePresented)
    }
}
