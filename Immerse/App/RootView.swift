import SwiftUI

/// 主窗口：左侧栏 + 日历，底部浮着轻提示
struct RootView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            CalendarContainerView()
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
        }
    }
}
