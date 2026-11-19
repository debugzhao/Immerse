import SwiftUI

/// Main calendar area: top bar + current view + keyboard shortcuts (event details are edited in a centered popup)
struct CalendarContainerView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine
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
            .focusable()
            .focusEffectDisabled()
            .focused($isCalendarFocused)
            .onAppear { isCalendarFocused = true }
            // After selecting an event and closing the popup, pull keyboard focus back to the calendar so single-key shortcuts like ⌫ and Space work
            .onChange(of: store.selectedTaskID) { _, _ in
                if !store.isEditorPresented { isCalendarFocused = true }
            }
            .onChange(of: store.isEditorPresented) { _, presented in
                if !presented { isCalendarFocused = true }
            }
            .onChange(of: store.wantsSearchFocus) { _, wants in
                guard wants else { return }
                isSearchFocused = true
                store.wantsSearchFocus = false
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard !store.isEditorPresented else { return .ignored }
                store.step(press.key == .leftArrow ? -1 : 1)
                return .handled
            }
            .onKeyPress(.space) { toggleFocus() }
            .onKeyPress(.return) { openSelection() }
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
            MonthView()
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

            Button {
                store.wrappedValue.isCommandPalettePresented = true
            } label: {
                Image(systemName: "command")
            }
            .help("命令面板（⌘K）")

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

    /// ↩: open the popup for the selected event
    private func openSelection() -> KeyPress.Result {
        guard !store.isEditorPresented, let id = store.selectedTaskID else { return .ignored }
        store.openEditor(id)
        return .handled
    }

    /// Space: pause / resume if the selected event is being focused, otherwise start focus; with no selection, control the current focus session
    private func toggleFocus() -> KeyPress.Result {
        guard !store.isEditorPresented else { return .ignored }
        if let task = taskStore.task(id: store.selectedTaskID), !focusEngine.isFocusing(on: task.id) {
            focusEngine.requestStart(task)
            return .handled
        }
        guard focusEngine.isActive else { return .ignored }
        focusEngine.togglePause()
        return .handled
    }

    private func deleteSelection() -> KeyPress.Result {
        guard !store.isEditorPresented, let id = store.selectedTaskID else { return .ignored }
        store.select(nil)
        taskStore.delete(id: id)
        return .handled
    }

    private func handleShortcut(_ press: KeyPress) -> KeyPress.Result {
        // Combos with ⌘ / ⌃ / ⌥ are left to the system menu
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]), !store.isEditorPresented else { return .ignored }
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
