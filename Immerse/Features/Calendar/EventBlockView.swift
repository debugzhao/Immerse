import SwiftUI

/// One event block in the time grid: translucent priority-colored fill + left color bar + title and time
struct EventBlockView: View {
    let task: TaskSnapshot
    let isSelected: Bool
    let height: CGFloat

    @Environment(CalendarStore.self) private var store
    @Environment(FocusEngine.self) private var focusEngine

    private var isDone: Bool { task.status == .done }
    private var color: Color { isDone ? .gray : task.priority.color }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        content(shape)
            .overlay(alignment: .topTrailing) {
                // Show a "start focus" quick button on hover: wide blocks show "▶ 专注", narrow ones show only the icon
                if store.hoveredTaskID == task.id && !isDone && !focusEngine.isFocusing(on: task.id) && height >= 22 {
                    Button {
                        focusEngine.requestStart(task)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            focusButtonLabel(showsText: true)
                            focusButtonLabel(showsText: false)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("开始专注 \(task.focusMinutes) 分钟")
                    .transition(.opacity)
                }
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    if hovering {
                        store.hoveredTaskID = task.id
                    } else if store.hoveredTaskID == task.id {
                        store.hoveredTaskID = nil
                    }
                }
            }
    }

    private func focusButtonLabel(showsText: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            if showsText {
                Text("专注")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, showsText ? 7 : 0)
        .frame(width: showsText ? nil : 18, height: 18)
        .background(Capsule().fill(color))
    }

    private func content(_ shape: RoundedRectangle) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
            GeometryReader { geometry in
                // Narrow blocks (events side by side) can't fit the time; give all space to the title, as many lines as the height allows
                let isNarrow = geometry.size.width < 64
                // Compact blocks (short events stacked back to back) get a smaller one-line title
                let isCompact = height < 16
                let showsSubtitle = !isNarrow && height >= 34
                let titleLines = max(1, Int((height - (showsSubtitle ? 22 : 6)) / 15))
                VStack(alignment: .leading, spacing: 1) {
                    // Sessions booked for a goal carry a small target mark
                    (task.goalID != nil ? Text(Image(systemName: "target")) + Text(" ") + Text(task.displayTitle) : Text(task.displayTitle))
                        .font(.system(size: isCompact ? 10 : isNarrow ? 11 : 12, weight: .semibold))
                        .strikethrough(isDone)
                        .lineLimit(min(titleLines, showsSubtitle ? 2 : 6))
                    if showsSubtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isDone ? .secondary : .primary)
                .padding(.leading, isNarrow ? 4 : 6)
                .padding(.trailing, isNarrow ? 2 : 4)
                .padding(.vertical, height >= 34 ? 4 : isCompact ? 0 : 2)
                // A one-line compact block centers its title so it isn't clipped at the bottom
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: isCompact ? .leading : .topLeading)
            }
        }
        .background(color.opacity(fillOpacity), in: shape)
        .clipShape(shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(color, lineWidth: 1.5)
            }
        }
        .modifier(BreathingGlow(isActive: task.status == .inProgress, color: color))
        .contentShape(shape)
        .onTapGesture { store.select(task.id) }
        // Double-click opens the popup (single click selects immediately, without waiting for double-click detection)
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.openEditor(task.id) })
        .taskContextMenu(task)
        .help(tooltip)
        .animation(Motion.snappy, value: isSelected)
    }

    private var fillOpacity: Double {
        if isDone { return Palette.eventFillOpacityDone }
        return isSelected ? Palette.eventFillOpacitySelected : Palette.eventFillOpacity
    }

    private var subtitle: String {
        let interval = task.displayInterval(in: store.calendar)
        let time = TimeText.range(interval.start, interval.end, calendar: store.calendar)
        guard let place = task.place, !place.isEmpty else { return time }
        return "\(time) · \(place)"
    }

    private var tooltip: String {
        "\(task.displayTitle)\n\(subtitle)\n\(task.priority.title) · \(task.status.title)"
    }
}

/// In-progress task: border and shadow pulse. With system "Reduce Motion" on, only a static outline remains.
struct BreathingGlow: ViewModifier {
    let isActive: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if !isActive {
            content
        } else if reduceMotion {
            content.overlay { shape.strokeBorder(color, lineWidth: 1.5) }
        } else {
            content.phaseAnimator([false, true]) { view, glowing in
                view
                    .overlay { shape.strokeBorder(color.opacity(glowing ? 0.95 : 0.35), lineWidth: 1.5) }
                    .shadow(color: color.opacity(glowing ? 0.5 : 0.1), radius: glowing ? 8 : 2)
            } animation: { _ in
                Motion.breathing
            }
        }
    }
}

// MARK: - Context menu

extension View {
    /// Context menu for an event, shared by calendar blocks, all-day bars, and the sidebar list
    func taskContextMenu(_ task: TaskSnapshot) -> some View {
        modifier(TaskContextMenu(task: task))
    }
}

private struct TaskContextMenu: ViewModifier {
    let task: TaskSnapshot
    @Environment(TaskStore.self) private var taskStore
    @Environment(CalendarStore.self) private var store
    @Environment(FocusEngine.self) private var focusEngine

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("打开") { store.openEditor(task.id) }
            Divider()
            if !focusEngine.isFocusing(on: task.id) && task.status != .done {
                Button("开始专注 \(task.focusMinutes) 分钟") { focusEngine.requestStart(task) }
                Divider()
            }
            Button(task.status == .done ? "标记为未完成" : "标记完成") {
                taskStore.toggleDone(task.id)
            }
            Menu("优先级") {
                ForEach(Priority.allCases) { priority in
                    Button {
                        taskStore.setPriority(priority, for: task.id)
                    } label: {
                        if priority == task.priority {
                            Label(priority.title, systemImage: "checkmark")
                        } else {
                            Text(priority.title)
                        }
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                if store.selectedTaskID == task.id { store.select(nil) }
                taskStore.delete(id: task.id)
            }
        }
    }
}
