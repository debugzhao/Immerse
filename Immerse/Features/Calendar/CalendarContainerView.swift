import SwiftUI

/// Main calendar area: top bar + current view + keyboard shortcuts (event details are edited in a centered popup)
struct CalendarContainerView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(TaskStore.self) private var taskStore
    @Environment(FocusEngine.self) private var focusEngine
    @FocusState private var isCalendarFocused: Bool
    @FocusState private var isSearchFocused: Bool
    /// Opacity of the time grid during a day ↔ week switch
    @State private var gridFade: Double = 1
    /// The user's choice for the planning panel, remembered across launches
    @AppStorage(PlanningPanel.visibilityKey) private var isPanelPreferred = true
    /// Shown floating over the calendar when the window is too narrow to keep it docked
    @State private var isPanelFloating = false
    @State private var detailWidth: CGFloat = 1200

    private var panelFitsDocked: Bool {
        detailWidth - PlanningPanel.width >= PlanningPanel.minimumCalendarWidth
    }

    /// What the toolbar toggle controls: the remembered preference when there's room, a floating panel otherwise
    private var panelVisibility: Binding<Bool> {
        Binding(
            get: { panelFitsDocked ? isPanelPreferred : isPanelFloating },
            set: { if panelFitsDocked { isPanelPreferred = $0 } else { isPanelFloating = $0 } }
        )
    }

    var body: some View {
        @Bindable var store = store

        // The toolbar is attached outside the single-key shortcut handlers below. If the search field sat inside them,
        // onKeyPress would grab key presses before the input method and Chinese (pinyin) input would break.
        HStack(spacing: 0) {
            calendarArea
            if panelFitsDocked && isPanelPreferred {
                PlanningPanel()
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay(alignment: .trailing) {
            if !panelFitsDocked && isPanelFloating {
                PlanningPanel()
                    .shadow(color: .black.opacity(0.15), radius: 12, x: -2)
                    .transition(.move(edge: .trailing))
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { detailWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in detailWidth = width }
            }
        }
        .onChange(of: panelFitsDocked) { _, fits in
            if fits { isPanelFloating = false }
        }
        .toolbar { toolbarContent(store: $store) }
    }

    private var calendarArea: some View {
        VStack(spacing: 0) {
            GoalRibbon()
            modeTransitionContainer
        }
        .animation(Motion.snappy, value: taskStore.goals().count)
            .overlay(alignment: .topTrailing) {
                if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView()
                        .padding(12)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Motion.snappy, value: store.searchText.isEmpty)
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

    /// Day / week / month switching.
    ///
    /// Both calendars stay alive and only their opacity changes. Rebuilding the view on every switch (`.id(mode)`) recreated
    /// the scroll view and re-laid-out the whole grid (~100 ms main-thread stall: the old view lingered, then jumped), and
    /// animating scale / layout made AppKit re-lay-out every platform subview on each frame. Opacity is composited on the
    /// GPU, so only opacity is animated:
    /// - grid ↔ month crossfade
    /// - week ↔ day swaps the columns instantly (same grid, scroll position kept) under a short fade-in
    private var modeTransitionContainer: some View {
        let showsGrid = store.mode != .month
        return ZStack {
            TimeGridCalendarView(days: store.gridDays)
                .animation(.easeOut(duration: 0.2)) { $0.opacity(showsGrid ? gridFade : 0) }
                .allowsHitTesting(showsGrid)
                .accessibilityHidden(!showsGrid)
            MonthView()
                .animation(.easeOut(duration: 0.2)) { $0.opacity(showsGrid ? 0 : 1) }
                .allowsHitTesting(!showsGrid)
                .accessibilityHidden(showsGrid)
        }
        .clipped()
        .onChange(of: store.mode) { old, new in
            // Day ↔ week: dip and fade back in so the column change doesn't just snap
            guard old != .month, new != .month else { return }
            gridFade = 0.35
            withAnimation(.easeOut(duration: 0.2)) { gridFade = 1 }
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

            PlanningPanelToggle(isVisible: panelVisibility)
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
