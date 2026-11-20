import SwiftUI

/// Left sidebar: mini month, today's tasks and the focus summary. The Inbox and Goals live in the planning panel on
/// the right of the calendar, so they stay in view instead of hiding behind a tab.
/// The system sidebar vibrancy comes from NavigationSplitView.
struct SidebarView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MiniMonthView()
                TodayTaskList()
                FocusSummaryView()
                    .padding(.top, 10)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }
}

/// Sidebar section title
struct SidebarSectionHeader: View {
    let title: String
    var icon: String?
    var trailing: String?
    /// Colored pill after the title for things that need attention ("2 条搁置", "1 个落后")
    var badge: String?
    var badgeColor: Color = .orange

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
            }
            Text(title)
            if let badge {
                AttentionPill(text: badge, color: badgeColor)
            }
            Spacer()
            if let trailing {
                Text(trailing).monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

/// Small tinted capsule used for "搁置 N 天" / "N 个落后"
struct AttentionPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// Empty-state hint shown when a panel has nothing in it
struct SidebarEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// Shared row background for the Today / Inbox / Goals lists:
/// a soft gray wash on hover, the accent tint when selected (selection wins over hover)
private struct SidebarRowBackground: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(isHovering ? 0.07 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

extension View {
    func sidebarRowBackground(isSelected: Bool) -> some View {
        modifier(SidebarRowBackground(isSelected: isSelected))
    }
}
