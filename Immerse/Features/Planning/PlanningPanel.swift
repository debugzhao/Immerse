import ImmerseCore
import SwiftUI

/// Right-hand planning panel: Inbox and Goals side by side with the calendar, so they stay in view
/// and dragging an item onto the calendar is a short trip. Shown as an inspector column; open / closed is remembered.
struct PlanningPanel: View {
    static let width: CGFloat = 248
    static let minimumWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 360
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
        .background(SidebarBackground())
    }
}

/// Toolbar button that opens / closes the planning panel. While closed it shows how many ideas wait in the Inbox
struct PlanningPanelToggle: View {
    @AppStorage(PlanningPanel.visibilityKey) private var isVisible = true
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

/// Background shared by the left sidebar and the planning panel, so the two match exactly.
/// Blends with the window rather than the desktop (`.withinWindow`): a desktop-tinted material takes its color from
/// whatever wallpaper sits behind each side, so the left and right edges of the window came out in different grays.
struct SidebarBackground: View {
    var body: some View {
        VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
            .ignoresSafeArea()
    }
}
