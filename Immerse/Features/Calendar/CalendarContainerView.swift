import SwiftUI

/// 日历主区域：顶栏 + 当前视图 + 右侧详情面板 + 键盘快捷键
struct CalendarContainerView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @FocusState private var isCalendarFocused: Bool
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var store = store

        content
            .overlay(alignment: .topTrailing) {
                if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView()
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.snappy, value: store.searchText.isEmpty)
            .toolbar { toolbarContent(store: $store) }
            .inspector(isPresented: inspectorBinding) {
                Group {
                    if let id = store.selectedTaskID {
                        TaskInspectorView(taskID: id)
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isCalendarFocused)
            .onAppear { isCalendarFocused = true }
            // 选中日程后把键盘焦点拉回日历，保证 ⌫、Space 等单键快捷键可用（新建时除外，标题框要焦点）
            .onChange(of: store.selectedTaskID) { _, _ in
                if !store.wantsTitleFocus { isCalendarFocused = true }
            }
            .onChange(of: store.wantsSearchFocus) { _, wants in
                guard wants else { return }
                isSearchFocused = true
                store.wantsSearchFocus = false
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                store.step(press.key == .leftArrow ? -1 : 1)
                return .handled
            }
            .onKeyPress(.delete) { deleteSelection() }
            .onKeyPress(.deleteForward) { deleteSelection() }
            .onKeyPress(.escape) {
                if store.draft != nil { store.draft = nil; return .handled }
                if store.selectedTaskID != nil { store.select(nil); return .handled }
                return .ignored
            }
            .onKeyPress(characters: .letters, phases: .down) { press in
                handleShortcut(press)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.mode {
        case .day, .week:
            TimeGridCalendarView(days: store.visibleDays)
        case .month:
            ContentUnavailableView(
                "月视图开发中",
                systemImage: "calendar",
                description: Text("将在 M5 阶段实现，按 W 回到周视图")
            )
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(store: Bindable<CalendarStore>) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.wrappedValue.title)
                    .font(.title3.weight(.semibold))
                if store.wrappedValue.mode != .month {
                    Text(verbatim: "第\(store.wrappedValue.weekNumber)周")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .contentTransition(.numericText())
            .animation(Motion.snappy, value: store.wrappedValue.title)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("今天") { store.wrappedValue.goToToday() }
                .help("回到今天（T）")
            ControlGroup {
                Button { store.wrappedValue.step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("上一页（J / ←）")
                Button { store.wrappedValue.step(1) } label: { Image(systemName: "chevron.right") }
                    .help("下一页（K / →）")
            }
            Picker("视图", selection: store.mode) {
                ForEach(CalendarMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("切换视图（D / W / M）")

            searchField(text: store.searchText)
        }
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索日程（⌘F）", text: text)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onKeyPress(.escape) {
                    text.wrappedValue = ""
                    isCalendarFocused = true
                    return .handled
                }
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 200)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { store.selectedTaskID != nil },
            set: { if !$0 { store.select(nil) } }
        )
    }

    private func deleteSelection() -> KeyPress.Result {
        guard let id = store.selectedTaskID else { return .ignored }
        store.select(nil)
        taskStore.delete(id: id)
        return .handled
    }

    private func handleShortcut(_ press: KeyPress) -> KeyPress.Result {
        // 带 ⌘ / ⌃ / ⌥ 的组合键交给系统菜单处理
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.characters.lowercased() {
        case "t": store.goToToday()
        case "d": store.mode = .day
        case "w": store.mode = .week
        case "m": store.mode = .month
        case "j": store.step(-1)
        case "k": store.step(1)
        default: return .ignored
        }
        return .handled
    }
}
