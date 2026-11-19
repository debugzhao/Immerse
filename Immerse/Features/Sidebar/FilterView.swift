import SwiftUI

/// Sidebar filters: filter events shown on the calendar by priority and status
struct FilterView: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SidebarSectionHeader(title: "筛选")
                if store.isFiltering {
                    Button("重置") { withAnimation(Motion.snappy) { store.resetFilters() } }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
            FlowChips {
                ForEach(Priority.allCases) { priority in
                    FilterChip(title: priority.title, color: priority.color,
                               isOn: store.priorityFilter.contains(priority)) {
                        store.toggle(priority)
                    }
                }
            }
            FlowChips {
                ForEach(TaskStatus.allCases) { status in
                    FilterChip(title: status.title, color: .gray,
                               isOn: store.statusFilter.contains(status)) {
                        store.toggle(status)
                    }
                }
            }
        }
    }
}

private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 6) { content }
    }
}

private struct FilterChip: View {
    let title: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(Motion.snappy, action) }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isOn ? AnyShapeStyle(color) : AnyShapeStyle(.clear))
                    .overlay { Circle().strokeBorder(color, lineWidth: 1) }
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(isOn ? 0.08 : 0.03), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
