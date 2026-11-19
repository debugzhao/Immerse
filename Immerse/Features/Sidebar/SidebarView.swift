import SwiftUI

/// Left sidebar: mini month calendar + today's tasks + filters. The system sidebar vibrancy comes from NavigationSplitView.
struct SidebarView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MiniMonthView()
                TodayTaskList()
                FocusSummaryView()
                FilterView()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

/// Sidebar section title
struct SidebarSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing).monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}
