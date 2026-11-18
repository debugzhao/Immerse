import SwiftUI

/// 日历主区域：顶栏 + 当前视图 + 键盘快捷键
struct CalendarContainerView: View {
    @Environment(CalendarStore.self) private var store
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var store = store

        content
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(store.title)
                            .font(.title3.weight(.semibold))
                        Text(verbatim: "第\(store.weekNumber)周")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: store.title)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("今天") { store.goToToday() }
                        .help("回到今天（T）")
                    ControlGroup {
                        Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                            .help("上一页（J / ←）")
                        Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                            .help("下一页（K / →）")
                    }
                    Picker("视图", selection: $store.mode) {
                        ForEach(CalendarMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("切换视图（D / W / M）")
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                store.step(press.key == .leftArrow ? -1 : 1)
                return .handled
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
