import SwiftUI

/// 左侧栏：迷你月历 + 今日任务 + 筛选。背景由 NavigationSplitView 提供系统侧栏毛玻璃。
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

/// 侧栏分区标题
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
