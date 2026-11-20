import ImmerseCore
import SwiftUI

/// Right-hand planning panel: Inbox and Goals side by side with the calendar, so they stay in view
/// and dragging an item onto the calendar is a short trip. Open / closed is remembered.
struct PlanningPanel: View {
    static let width: CGFloat = 248
    /// Below this calendar width the panel is hidden automatically (the calendar would get too cramped)
    static let minimumCalendarWidth: CGFloat = 560
    static let visibilityKey = "planningPanel.visible"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                InboxSection()
                GoalsSection()
                Text("拖到日历上排期，拖到同一列表的其他行上调整顺序")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(width: Self.width)
        .background(VisualEffectBackground(material: .sidebar))
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.gridLine).frame(width: 0.5)
        }
    }
}

/// Toolbar button that opens / closes the planning panel. While closed it shows how many ideas wait in the Inbox
struct PlanningPanelToggle: View {
    @Binding var isVisible: Bool
    @Environment(TaskStore.self) private var taskStore

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isVisible.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sidebar.right")
                let count = taskStore.ideas().count
                if !isVisible && count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        .help(isVisible ? "收起规划面板（⌥⌘P）" : "打开规划面板：收集箱和目标（⌥⌘P）")
    }
}
