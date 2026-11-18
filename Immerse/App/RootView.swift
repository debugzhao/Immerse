import SwiftUI

/// 主窗口：左侧栏 + 日历，底部浮着轻提示，时间到时浮出提醒面板
struct RootView: View {
    @Environment(FocusEngine.self) private var focusEngine
    @Environment(SettingsStore.self) private var settings
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(\.openWindow) private var openWindow
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
        .overlay {
            CommandPaletteOverlay()
        }
        .overlay {
            ImmersiveOverlay()
        }
        .overlay {
            FocusTimeUpOverlay()
        }
        // 首次启动：勿扰设置引导
        .sheet(isPresented: Binding(
            get: { (!settings.onboardingCompleted && !PersistenceController.isEphemeral) || DebugFlags.forceOnboarding },
            set: { if !$0 { settings.onboardingCompleted = true } }
        )) {
            OnboardingSheet()
        }
        .sheet(item: Bindable(calendarStore).pendingImport) { preview in
            ImportPreviewView(preview: preview)
        }
        .onAppear {
            if DebugFlags.openStats { openWindow(id: "stats") }
        }
        .alert(
            "已有进行中的专注",
            isPresented: Binding(
                get: { focusEngine.pendingSwitch != nil },
                set: { if !$0 { focusEngine.pendingSwitch = nil } }
            ),
            presenting: focusEngine.pendingSwitch
        ) { _ in
            Button("结束当前并开始新的") { focusEngine.confirmSwitch() }
            Button("取消", role: .cancel) { focusEngine.pendingSwitch = nil }
        } message: { task in
            Text("「\(focusEngine.session?.taskTitle ?? "")」还在专注中。要放弃它，开始「\(task.displayTitle)」吗？")
        }
    }
}
