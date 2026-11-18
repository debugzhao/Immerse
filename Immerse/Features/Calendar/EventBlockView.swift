import SwiftUI

/// 时间网格里的一个日程块：优先级色半透明填充 + 左侧色条 + 标题和时间
struct EventBlockView: View {
    let task: TaskSnapshot
    let isSelected: Bool
    let height: CGFloat

    @Environment(CalendarStore.self) private var store

    private var isDone: Bool { task.status == .done }
    private var color: Color { isDone ? .gray : task.priority.color }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

        HStack(spacing: 0) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12, weight: .semibold))
                    .strikethrough(isDone)
                    .lineLimit(height > 44 ? 2 : 1)
                if height >= 34 {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isDone ? .secondary : .primary)
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .padding(.vertical, height >= 34 ? 4 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        "\(task.title)\n\(subtitle)\n\(task.priority.title) · \(task.status.title)"
    }
}

/// 进行中的任务：边框和阴影做呼吸效果。系统开启「减少动态效果」时只保留静态描边。
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
